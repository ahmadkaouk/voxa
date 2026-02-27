mod adapters;
mod secrets;
mod server;

use std::env;
use std::io;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

pub fn run_forever() -> io::Result<()> {
    let running = Arc::new(AtomicBool::new(true));
    run_with_flag(default_socket_path()?, running)
}

pub fn run_with_flag(socket_path: PathBuf, running: Arc<AtomicBool>) -> io::Result<()> {
    if !running.load(Ordering::SeqCst) {
        return Ok(());
    }

    server::run(socket_path, running)
}

pub fn default_socket_path() -> io::Result<PathBuf> {
    if let Some(path) = env::var_os("VOICO_SOCKET") {
        return Ok(PathBuf::from(path));
    }

    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::other("HOME is not set"))?;

    Ok(home.join("Library/Application Support/voico-v2/run/daemon.sock"))
}
