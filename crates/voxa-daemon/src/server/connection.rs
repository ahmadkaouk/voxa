use std::io::{self, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, mpsc};
use std::thread;

use voxa_core::ipc::ServerEnvelope;

// A healthy local client drains this queue almost immediately. Sixty-four messages
// leave room for short scheduling stalls while putting a hard memory bound on a
// client that stops reading from its socket.
pub(super) const OUTBOUND_QUEUE_CAPACITY: usize = 64;

#[derive(Clone)]
pub(super) struct ConnectionHandle {
    tx: mpsc::SyncSender<OutboundMessage>,
    shutdown_stream: Arc<UnixStream>,
}

enum OutboundMessage {
    Envelope(ServerEnvelope),
    Close,
}

impl ConnectionHandle {
    pub(super) fn new(mut stream: UnixStream) -> io::Result<Self> {
        let shutdown_stream = Arc::new(stream.try_clone()?);
        let (tx, rx) = mpsc::sync_channel::<OutboundMessage>(OUTBOUND_QUEUE_CAPACITY);
        thread::spawn(move || {
            while let Ok(OutboundMessage::Envelope(envelope)) = rx.recv() {
                if write_envelope(&mut stream, &envelope).is_err() {
                    break;
                }
            }
            let _ = stream.shutdown(Shutdown::Both);
        });

        Ok(Self {
            tx,
            shutdown_stream,
        })
    }

    pub(super) fn send(&self, envelope: ServerEnvelope) -> io::Result<()> {
        self.tx
            .try_send(OutboundMessage::Envelope(envelope))
            .map_err(map_queue_send_error)
    }

    pub(super) fn same_connection(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.shutdown_stream, &other.shutdown_stream)
    }

    /// Let the writer flush queued responses before shutting down the socket.
    pub(super) fn close(&self) {
        if self.tx.try_send(OutboundMessage::Close).is_err() {
            self.disconnect();
        }
    }

    pub(super) fn disconnect(&self) {
        let _ = self.shutdown_stream.shutdown(Shutdown::Both);
    }
}

fn map_queue_send_error<T>(error: mpsc::TrySendError<T>) -> io::Error {
    match error {
        mpsc::TrySendError::Full(_) => io::Error::new(
            io::ErrorKind::WouldBlock,
            "connection outbound queue is full",
        ),
        mpsc::TrySendError::Disconnected(_) => {
            io::Error::new(io::ErrorKind::BrokenPipe, "connection closed")
        }
    }
}

fn write_envelope(stream: &mut UnixStream, envelope: &ServerEnvelope) -> io::Result<()> {
    let serialized = serde_json::to_string(envelope)
        .map_err(|_| io::Error::other("failed to serialize message"))?;
    stream.write_all(serialized.as_bytes())?;
    stream.write_all(b"\n")?;
    stream.flush()
}

#[cfg(test)]
mod tests {
    use std::io::{self, Read};
    use std::os::unix::net::UnixStream;
    use std::sync::mpsc;

    use voxa_core::ipc::ServerEnvelope;

    use super::{ConnectionHandle, map_queue_send_error};

    fn envelope() -> ServerEnvelope {
        ServerEnvelope::HelloOk {
            api_version: "1.0".to_owned(),
            daemon_version: "test".to_owned(),
        }
    }

    #[test]
    fn full_outbound_queue_is_reported_without_blocking() {
        let (tx, _rx) = mpsc::sync_channel(1);
        tx.try_send(envelope()).expect("first message should fit");

        let error = map_queue_send_error(
            tx.try_send(envelope())
                .expect_err("second message should exceed capacity"),
        );

        assert_eq!(error.kind(), io::ErrorKind::WouldBlock);
    }

    #[test]
    fn disconnected_outbound_queue_is_reported_as_broken_pipe() {
        let (tx, rx) = mpsc::sync_channel(1);
        drop(rx);

        let error = map_queue_send_error(
            tx.try_send(envelope())
                .expect_err("send should fail after receiver closes"),
        );

        assert_eq!(error.kind(), io::ErrorKind::BrokenPipe);
    }

    #[test]
    fn disconnect_closes_the_peer_socket() {
        let (server, mut client) = UnixStream::pair().expect("socket pair should open");
        let connection = ConnectionHandle::new(server).expect("connection should initialize");

        connection.disconnect();

        let mut byte = [0_u8; 1];
        assert_eq!(
            client.read(&mut byte).expect("peer read should complete"),
            0
        );
    }
}
