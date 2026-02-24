#[derive(Debug, Clone, Copy)]
pub enum AppError {
    InvalidModel,
    InvalidMaxSeconds,
}

impl AppError {
    pub fn print(self) {
        match self {
            Self::InvalidModel => {
                eprintln!("ERROR E_CFG_INVALID_MODEL: model value is invalid.");
                eprintln!("Use gpt-4o-mini-transcribe or gpt-4o-transcribe.");
            }
            Self::InvalidMaxSeconds => {
                eprintln!("ERROR E_CFG_INVALID_MAX_SECONDS: max-seconds must be > 0.");
                eprintln!("Use --max-seconds <positive integer>.");
            }
        }
    }
}
