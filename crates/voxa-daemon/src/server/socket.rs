use std::fs::{self, DirBuilder, Metadata, Permissions};
use std::io;
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

pub(super) struct BoundSocket {
    pub(super) listener: UnixListener,
    path: PathBuf,
    metadata: Metadata,
}

impl BoundSocket {
    pub(super) fn bind(path: PathBuf) -> io::Result<Self> {
        if let Some(parent) = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
        {
            DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(parent)?;
            // Only tighten the app-owned directory. A custom socket may be in
            // a shared directory such as /tmp, whose permissions we must preserve.
            if voxa_core::ipc::default_runtime_directory().ok().as_deref() == Some(parent) {
                fs::set_permissions(parent, Permissions::from_mode(0o700))?;
            }
        }
        ensure_socket_available(&path)?;
        let listener = UnixListener::bind(&path)?;
        let metadata = fs::symlink_metadata(&path)?;
        let socket = Self {
            listener,
            path,
            metadata,
        };
        fs::set_permissions(&socket.path, Permissions::from_mode(0o600))?;
        socket.listener.set_nonblocking(true)?;
        Ok(socket)
    }
}

impl Drop for BoundSocket {
    fn drop(&mut self) {
        if let Ok(metadata) = fs::symlink_metadata(&self.path) {
            if same_file(&self.metadata, &metadata) {
                let _ = fs::remove_file(&self.path);
            }
        }
    }
}

fn same_file(a: &Metadata, b: &Metadata) -> bool {
    a.dev() == b.dev() && a.ino() == b.ino() && b.file_type().is_socket()
}

pub(super) fn ensure_socket_available(path: &Path) -> io::Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    if !metadata.file_type().is_socket() {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "socket path is not a socket",
        ));
    }
    match UnixStream::connect(path) {
        Ok(_) => Err(io::Error::new(
            io::ErrorKind::AddrInUse,
            "voxa-daemon is already running",
        )),
        Err(error) if error.kind() == io::ErrorKind::ConnectionRefused => {
            // Do not remove a file replaced while the connection was checked.
            let current = fs::symlink_metadata(path)?;
            if !same_file(&metadata, &current) {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "socket path changed",
                ));
            }
            fs::remove_file(path)
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn test_directory() -> PathBuf {
        std::env::temp_dir().join(format!(
            "vx-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    #[test]
    fn new_runtime_directory_is_private_and_shared_directory_is_preserved() {
        let directory = test_directory();
        let path = directory.join("d.sock");
        let socket = BoundSocket::bind(path.clone()).unwrap();
        assert_eq!(
            fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        drop(socket);
        assert!(!path.exists());
        fs::set_permissions(&directory, Permissions::from_mode(0o755)).unwrap();
        let socket = BoundSocket::bind(path).unwrap();
        assert_eq!(
            fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
            0o755
        );
        drop(socket);
        fs::remove_dir(directory).unwrap();
    }

    #[test]
    fn stale_socket_is_replaced_but_symlinks_and_files_are_preserved() {
        let directory = test_directory();
        fs::create_dir(&directory).unwrap();
        let path = directory.join("d.sock");
        drop(UnixListener::bind(&path).unwrap());
        let socket = BoundSocket::bind(path.clone()).unwrap();
        assert!(UnixStream::connect(&path).is_ok());
        drop(socket);
        let target = directory.join("target");
        fs::write(&target, "preserve me").unwrap();
        std::os::unix::fs::symlink(&target, &path).unwrap();
        assert!(
            matches!(BoundSocket::bind(path.clone()), Err(error) if error.kind() == io::ErrorKind::AlreadyExists)
        );
        assert!(
            fs::symlink_metadata(&path)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(fs::read_to_string(&target).unwrap(), "preserve me");
        fs::remove_file(&target).unwrap();
        assert!(
            ensure_socket_available(&path).is_err(),
            "dangling links must also be preserved"
        );
        assert!(fs::symlink_metadata(&path).is_ok());
        fs::remove_file(&path).unwrap();
        fs::remove_dir(directory).unwrap();
    }

    #[test]
    fn shutdown_preserves_replacement_at_socket_path() {
        let directory = test_directory();
        let path = directory.join("d.sock");
        let socket = BoundSocket::bind(path.clone()).unwrap();
        fs::remove_file(&path).unwrap();
        fs::write(&path, "replacement").unwrap();
        drop(socket);
        assert_eq!(fs::read_to_string(&path).unwrap(), "replacement");
        fs::remove_file(path).unwrap();
        fs::remove_dir(directory).unwrap();
    }
}
