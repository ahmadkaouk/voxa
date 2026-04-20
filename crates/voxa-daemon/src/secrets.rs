use std::env;
use std::io;
use std::process::Command;
#[cfg(test)]
use std::sync::{Arc, Mutex};

const SECURITY_BIN: &str = "/usr/bin/security";
const KEYCHAIN_SERVICE: &str = "com.voxa";
const KEYCHAIN_ACCOUNT: &str = "OPENAI_API_KEY";

pub(crate) trait ApiKeyStore: Send {
    fn get_api_key(&self) -> io::Result<Option<String>>;
    fn set_api_key(&self, api_key: &str) -> io::Result<()>;
}

pub(crate) fn build_api_key_store(source: &str) -> Box<dyn ApiKeyStore> {
    match source {
        "env" => Box::new(EnvApiKeyStore),
        _ => Box::new(KeychainApiKeyStore),
    }
}

struct KeychainApiKeyStore;

impl ApiKeyStore for KeychainApiKeyStore {
    fn get_api_key(&self) -> io::Result<Option<String>> {
        let keychain_path = default_user_keychain_path();
        let output = security_command([
            "find-generic-password",
            "-a",
            KEYCHAIN_ACCOUNT,
            "-s",
            KEYCHAIN_SERVICE,
            "-w",
        ], keychain_path.as_deref())
        .output();

        let output = match output {
            Ok(output) => output,
            Err(err) if err.kind() == io::ErrorKind::NotFound => {
                return Ok(env_api_key());
            }
            Err(err) => return Err(err),
        };

        if output.status.success() {
            let value = String::from_utf8_lossy(&output.stdout).trim().to_owned();
            if value.is_empty() {
                return Ok(env_api_key());
            }

            return Ok(Some(value));
        }

        let stderr = String::from_utf8_lossy(&output.stderr).to_lowercase();
        if stderr.contains("could not be found") {
            return Ok(env_api_key());
        }

        Err(security_command_error(
            &output.stderr,
            "failed to read keychain api key",
        ))
    }

    fn set_api_key(&self, api_key: &str) -> io::Result<()> {
        let keychain_path = default_user_keychain_path();
        let output = security_command([
            "add-generic-password",
            "-U",
            "-a",
            KEYCHAIN_ACCOUNT,
            "-s",
            KEYCHAIN_SERVICE,
            "-w",
            api_key,
        ], keychain_path.as_deref())
        .output();

        let output = match output {
            Ok(output) => output,
            Err(err) if err.kind() == io::ErrorKind::NotFound => {
                return Err(io::Error::other("security binary not found"));
            }
            Err(err) => return Err(err),
        };

        if output.status.success() {
            return Ok(());
        }

        Err(security_command_error(
            &output.stderr,
            "failed to write keychain api key",
        ))
    }
}

struct EnvApiKeyStore;

impl ApiKeyStore for EnvApiKeyStore {
    fn get_api_key(&self) -> io::Result<Option<String>> {
        Ok(env_api_key())
    }

    fn set_api_key(&self, _api_key: &str) -> io::Result<()> {
        Err(io::Error::other("api key source is env and is read-only"))
    }
}

fn env_api_key() -> Option<String> {
    env::var("OPENAI_API_KEY")
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

fn security_command<const N: usize>(
    args: [&str; N],
    keychain_path: Option<&str>,
) -> Command {
    let mut command = Command::new(SECURITY_BIN);
    command.args(args);
    if let Some(keychain_path) = keychain_path {
        command.arg(keychain_path);
    }
    command
}

fn default_user_keychain_path() -> Option<String> {
    let output = Command::new(SECURITY_BIN)
        .args(["default-keychain", "-d", "user"])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    parse_security_keychain_path(&String::from_utf8_lossy(&output.stdout))
}

fn parse_security_keychain_path(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    let trimmed = trimmed.strip_prefix('"').unwrap_or(trimmed);
    let trimmed = trimmed.strip_suffix('"').unwrap_or(trimmed);
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_owned())
    }
}

fn security_command_error(stderr: &[u8], fallback: &str) -> io::Error {
    let detail = String::from_utf8_lossy(stderr).trim().to_owned();
    if detail.is_empty() {
        io::Error::other(fallback)
    } else {
        io::Error::other(format!("{fallback}: {detail}"))
    }
}

#[cfg(test)]
pub(crate) fn in_memory_api_key_store() -> Box<dyn ApiKeyStore> {
    Box::new(MemoryApiKeyStore {
        value: Arc::new(Mutex::new(None)),
    })
}

#[cfg(test)]
pub(crate) fn in_memory_api_key_store_with_shared(
    shared: Arc<Mutex<Option<String>>>,
) -> Box<dyn ApiKeyStore> {
    Box::new(MemoryApiKeyStore { value: shared })
}

#[cfg(test)]
struct MemoryApiKeyStore {
    value: Arc<Mutex<Option<String>>>,
}

#[cfg(test)]
impl ApiKeyStore for MemoryApiKeyStore {
    fn get_api_key(&self) -> io::Result<Option<String>> {
        let value = self
            .value
            .lock()
            .map_err(|_| io::Error::other("api key store poisoned"))?;
        Ok(value.clone())
    }

    fn set_api_key(&self, api_key: &str) -> io::Result<()> {
        let mut value = self
            .value
            .lock()
            .map_err(|_| io::Error::other("api key store poisoned"))?;
        *value = Some(api_key.to_owned());
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::parse_security_keychain_path;

    #[test]
    fn parses_quoted_keychain_path() {
        let parsed = parse_security_keychain_path(
            "    \"/Users/test/Library/Keychains/login.keychain-db\"\n",
        );
        assert_eq!(
            parsed.as_deref(),
            Some("/Users/test/Library/Keychains/login.keychain-db")
        );
    }

    #[test]
    fn returns_none_for_empty_keychain_path() {
        assert_eq!(parse_security_keychain_path("   \n"), None);
    }
}
