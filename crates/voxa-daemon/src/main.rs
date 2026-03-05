fn main() {
    if let Err(err) = voxa_daemon::run_forever() {
        eprintln!("ERROR VOXA_DAEMON_FAILED: {err}");
        std::process::exit(1);
    }
}
