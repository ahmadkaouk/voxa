#[derive(Debug, Clone, Copy)]
pub enum AppError {
    InvalidMaxSeconds,
}

impl AppError {
    pub fn print(self) {
        match self {
            Self::InvalidMaxSeconds => {
                eprintln!("ERROR CFG_INVALID_MAX_SECONDS: max-seconds must be > 0.");
                eprintln!("Use --max-seconds <positive integer>.");
            }
        }
    }
}
