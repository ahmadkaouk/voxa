pub mod app;
pub mod domain;
pub mod infra;
pub mod ipc;

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
