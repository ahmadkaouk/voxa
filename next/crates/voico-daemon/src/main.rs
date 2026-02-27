fn main() {
    if let Err(err) = voico_daemon::run_forever() {
        eprintln!("ERROR VOICO_DAEMON_FAILED: {err}");
        std::process::exit(1);
    }
}
