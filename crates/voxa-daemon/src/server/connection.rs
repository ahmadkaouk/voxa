use std::io::{self, Write};
use std::os::unix::net::UnixStream;
use std::sync::mpsc;
use std::thread;

use voxa_core::ipc::ServerEnvelope;

#[derive(Clone)]
pub(super) struct ConnectionHandle {
    tx: mpsc::Sender<ServerEnvelope>,
}

impl ConnectionHandle {
    pub(super) fn new(mut stream: UnixStream) -> Self {
        let (tx, rx) = mpsc::channel::<ServerEnvelope>();
        thread::spawn(move || {
            while let Ok(envelope) = rx.recv() {
                if write_envelope(&mut stream, &envelope).is_err() {
                    break;
                }
            }
        });

        Self { tx }
    }

    pub(super) fn send(&self, envelope: ServerEnvelope) -> io::Result<()> {
        self.tx
            .send(envelope)
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "connection closed"))
    }
}

fn write_envelope(stream: &mut UnixStream, envelope: &ServerEnvelope) -> io::Result<()> {
    let serialized = serde_json::to_string(envelope)
        .map_err(|_| io::Error::other("failed to serialize message"))?;
    stream.write_all(serialized.as_bytes())?;
    stream.write_all(b"\n")?;
    stream.flush()
}
