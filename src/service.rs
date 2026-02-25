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

    let _ = Command::new("launchctl")
        .arg("bootout")
        .arg(&domain)
        .arg(&plist_path)
        .status();

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

    let _ = Command::new("launchctl")
        .arg("bootout")
        .arg(&domain)
        .arg(&plist_path)
        .status();

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

    let loaded = Command::new("launchctl")
        .arg("print")
        .arg(&service_target)
        .status()
        .map(|status| status.success())
        .unwrap_or(false);

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
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{SERVICE_LABEL}</string>
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
        binary = binary_path.display(),
        stdout = stdout_log.display(),
        stderr = stderr_log.display(),
    )
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::{SERVICE_LABEL, build_plist};

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
}
