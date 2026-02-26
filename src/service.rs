use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::cli::ServiceCommand;
use crate::error::AppError;

const SERVICE_LABEL: &str = "com.voico.daemon";
const PLIST_FILE_NAME: &str = "com.voico.daemon.plist";

pub fn run(command: ServiceCommand) -> Result<(), AppError> {
    match command {
        ServiceCommand::Install => install(),
        ServiceCommand::Uninstall => uninstall(),
        ServiceCommand::Status => status(),
    }
}

fn install() -> Result<(), AppError> {
    let plist_path = plist_path()?;
    let home = home_dir()?;
    let log_dir = home.join("Library/Logs");
    fs::create_dir_all(&log_dir).map_err(|_| AppError::ServiceInstallFailed)?;

    if let Some(parent) = plist_path.parent() {
        fs::create_dir_all(parent).map_err(|_| AppError::ServiceInstallFailed)?;
    }

    let binary_path = env::current_exe().map_err(|_| AppError::ServiceInstallFailed)?;
    let stdout_log = log_dir.join("voico-daemon.out.log");
    let stderr_log = log_dir.join("voico-daemon.err.log");
    let plist = build_plist(&binary_path, &stdout_log, &stderr_log);
    fs::write(&plist_path, plist).map_err(|_| AppError::ServiceInstallFailed)?;

    let domain = launch_domain().map_err(|_| AppError::ServiceInstallFailed)?;
    let service_target = format!("{domain}/{SERVICE_LABEL}");

    // Ensure a previously-started foreground daemon doesn't run alongside the LaunchAgent.
    let _ = Command::new("/usr/bin/pkill")
        .arg("-f")
        .arg("(^|/)voico daemon$")
        .status();

    let _ = bootout_service(&domain, &plist_path);

    let bootstrap = Command::new("launchctl")
        .arg("bootstrap")
        .arg(&domain)
        .arg(&plist_path)
        .status()
        .map_err(|_| AppError::ServiceInstallFailed)?;
    if !bootstrap.success() {
        return Err(AppError::ServiceInstallFailed);
    }

    let _ = Command::new("launchctl")
        .arg("kickstart")
        .arg("-k")
        .arg(service_target)
        .status();

    println!("OK SERVICE_INSTALLED");
    println!("service = {SERVICE_LABEL}");
    println!("plist_path = {}", plist_path.display());

    Ok(())
}

fn uninstall() -> Result<(), AppError> {
    let plist_path = plist_path()?;
    let domain = launch_domain().map_err(|_| AppError::ServiceUninstallFailed)?;

    bootout_service(&domain, &plist_path).map_err(|_| AppError::ServiceUninstallFailed)?;

    if plist_path.exists() {
        fs::remove_file(&plist_path).map_err(|_| AppError::ServiceUninstallFailed)?;
    }

    println!("OK SERVICE_UNINSTALLED");
    println!("service = {SERVICE_LABEL}");

    Ok(())
}

fn status() -> Result<(), AppError> {
    let plist_path = plist_path()?;
    let domain = launch_domain().map_err(|_| AppError::ServiceStatusFailed)?;
    let service_target = format!("{domain}/{SERVICE_LABEL}");

    let output = Command::new("launchctl")
        .arg("print")
        .arg(&service_target)
        .output()
        .map_err(|_| AppError::ServiceStatusFailed)?;
    let loaded = parse_loaded_status(&output)?;

    println!("service = {SERVICE_LABEL}");
    println!("plist_path = {}", plist_path.display());
    println!("plist_present = {}", plist_path.exists());
    println!("loaded = {loaded}");

    Ok(())
}

fn plist_path() -> Result<PathBuf, AppError> {
    Ok(home_dir()?
        .join("Library/LaunchAgents")
        .join(PLIST_FILE_NAME))
}

fn home_dir() -> Result<PathBuf, AppError> {
    env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or(AppError::DaemonConfigPathUnavailable)
}

fn launch_domain() -> Result<String, std::io::Error> {
    let output = Command::new("id").arg("-u").output()?;
    if !output.status.success() {
        return Err(io::Error::other("failed to resolve user id"));
    }

    let uid = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if uid.is_empty() {
        return Err(io::Error::other("empty user id"));
    }

    Ok(format!("gui/{uid}"))
}

fn build_plist(binary_path: &Path, stdout_log: &Path, stderr_log: &Path) -> String {
    let service_label = xml_escape(SERVICE_LABEL);
    let binary = xml_escape(&binary_path.display().to_string());
    let stdout = xml_escape(&stdout_log.display().to_string());
    let stderr = xml_escape(&stderr_log.display().to_string());

    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{service_label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{binary}</string>
    <string>daemon</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>{stdout}</string>
  <key>StandardErrorPath</key>
  <string>{stderr}</string>
</dict>
</plist>
"#,
        service_label = service_label,
        binary = binary,
        stdout = stdout,
        stderr = stderr,
    )
}

fn parse_loaded_status(output: &std::process::Output) -> Result<bool, AppError> {
    if output.status.success() {
        return Ok(true);
    }

    let stderr = String::from_utf8_lossy(&output.stderr);
    let stderr_lower = stderr.to_ascii_lowercase();
    let is_not_loaded = output.status.code() == Some(113)
        || stderr_lower.contains("could not find service")
        || stderr_lower.contains("service not found");

    if is_not_loaded {
        Ok(false)
    } else {
        Err(AppError::ServiceStatusFailed)
    }
}

fn bootout_service(domain: &str, plist_path: &Path) -> Result<(), io::Error> {
    let output = Command::new("launchctl")
        .arg("bootout")
        .arg(domain)
        .arg(plist_path)
        .output()?;

    if output.status.success() || is_bootout_not_loaded(&output) {
        return Ok(());
    }

    Err(io::Error::other("launchctl bootout failed"))
}

fn is_bootout_not_loaded(output: &std::process::Output) -> bool {
    let stderr = String::from_utf8_lossy(&output.stderr);
    let stderr_lower = stderr.to_ascii_lowercase();
    output.status.code() == Some(5)
        || stderr_lower.contains("input/output error")
        || stderr_lower.contains("could not find service")
        || stderr_lower.contains("service not found")
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

#[cfg(test)]
mod tests {
    use std::os::unix::process::ExitStatusExt;
    use std::path::Path;
    use std::process::Output;

    use super::{
        SERVICE_LABEL, build_plist, is_bootout_not_loaded, parse_loaded_status,
    };
    use crate::error::AppError;

    #[test]
    fn plist_contains_required_fields() {
        let plist = build_plist(
            Path::new("/usr/local/bin/voico"),
            Path::new("/tmp/out.log"),
            Path::new("/tmp/err.log"),
        );

        assert!(plist.contains(SERVICE_LABEL));
        assert!(plist.contains("/usr/local/bin/voico"));
        assert!(plist.contains("<string>daemon</string>"));
        assert!(plist.contains("/tmp/out.log"));
        assert!(plist.contains("/tmp/err.log"));
    }

    #[test]
    fn plist_escapes_xml_special_characters() {
        let plist = build_plist(
            Path::new("/tmp/voice&<\"'"),
            Path::new("/tmp/out&<\"'.log"),
            Path::new("/tmp/err&<\"'.log"),
        );

        assert!(plist.contains("/tmp/voice&amp;&lt;&quot;&apos;"));
        assert!(plist.contains("/tmp/out&amp;&lt;&quot;&apos;.log"));
        assert!(plist.contains("/tmp/err&amp;&lt;&quot;&apos;.log"));
    }

    #[test]
    fn parse_loaded_status_maps_missing_service_to_false() {
        let output = Output {
            status: std::process::ExitStatus::from_raw(113 << 8),
            stdout: Vec::new(),
            stderr: b"Could not find service".to_vec(),
        };

        assert!(matches!(parse_loaded_status(&output), Ok(false)));
    }

    #[test]
    fn parse_loaded_status_maps_other_failures_to_error() {
        let output = Output {
            status: std::process::ExitStatus::from_raw(1 << 8),
            stdout: Vec::new(),
            stderr: b"Operation not permitted".to_vec(),
        };

        assert!(matches!(
            parse_loaded_status(&output),
            Err(AppError::ServiceStatusFailed)
        ));
    }

    #[test]
    fn bootout_not_loaded_is_treated_as_non_fatal() {
        let output = Output {
            status: std::process::ExitStatus::from_raw(5 << 8),
            stdout: Vec::new(),
            stderr: b"Boot-out failed: 5: Input/output error".to_vec(),
        };

        assert!(is_bootout_not_loaded(&output));
    }

    #[test]
    fn bootout_unrelated_failures_are_not_treated_as_not_loaded() {
        let output = Output {
            status: std::process::ExitStatus::from_raw(1 << 8),
            stdout: Vec::new(),
            stderr: b"Operation not permitted".to_vec(),
        };

        assert!(!is_bootout_not_loaded(&output));
    }
}
