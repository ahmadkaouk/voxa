#[derive(Debug, Clone, Copy)]
pub enum AppError {
    CfgApiKeyMissing,
    CfgInvalidModel,
    CfgInvalidLanguage,
    CfgInvalidMaxSeconds,
    CfgInvalidOutput,
}

impl AppError {
    pub fn print(self) {
        match self {
            Self::CfgApiKeyMissing => {
                eprintln!("ERROR CFG_API_KEY_MISSING: OPENAI_API_KEY is required.");
                eprintln!("Set OPENAI_API_KEY in your environment or .env file.");
            }
            Self::CfgInvalidModel => {
                eprintln!("ERROR CFG_INVALID_MODEL: model value is invalid.");
                eprintln!("Use gpt-4o-mini-transcribe or gpt-4o-transcribe.");
            }
            Self::CfgInvalidLanguage => {
                eprintln!("ERROR CFG_INVALID_LANGUAGE: language must be auto, en, or fr.");
                eprintln!("Run voico --help for valid options.");
            }
            Self::CfgInvalidMaxSeconds => {
                eprintln!("ERROR CFG_INVALID_MAX_SECONDS: max-seconds must be > 0.");
                eprintln!("Use --max-seconds <positive integer>.");
            }
            Self::CfgInvalidOutput => {
                eprintln!("ERROR CFG_INVALID_OUTPUT: output must be clipboard or stdout.");
                eprintln!("Use --output <clipboard|stdout>.");
            }
        }
    }
}
