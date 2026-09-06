mod adapters;
mod secrets;
mod server;

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

pub use voxa_core::ipc::default_socket_path;
