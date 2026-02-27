#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum SessionState {
    Idle,
    Recording(RecordingState),
    Transcribing,
    Outputting,
    Error,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub struct RecordingState {
    pub origin: RecordingOrigin,
    pub stop_requested: bool,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum RecordingOrigin {
    Toggle,
    Hold,
    Manual,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum DomainEvent {
    TogglePressed,
    HoldPressed,
    ManualPressed,
    HoldReleased,
    MaxDurationReached,
    RecordingStopped,
    RecordingFailed,
    TranscriptionSucceeded,
    TranscriptionFailed,
    OutputCompleted,
    OutputFailed,
    Reset,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum ApplyResult {
    Transitioned,
    Noop,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum DomainError {
    InvalidTransition {
        state: SessionStateTag,
        event: DomainEventTag,
    },
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum SessionStateTag {
    Idle,
    Recording,
    Transcribing,
    Outputting,
    Error,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum DomainEventTag {
    TogglePressed,
    HoldPressed,
    ManualPressed,
    HoldReleased,
    MaxDurationReached,
    RecordingStopped,
    RecordingFailed,
    TranscriptionSucceeded,
    TranscriptionFailed,
    OutputCompleted,
    OutputFailed,
    Reset,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum RuntimeErrorCode {
    AudioCaptureFailed,
    TranscriptionFailed,
    OutputFailed,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub struct SessionMachine {
    state: SessionState,
    last_error: Option<RuntimeErrorCode>,
}

impl Default for SessionMachine {
    fn default() -> Self {
        Self {
            state: SessionState::Idle,
            last_error: None,
        }
    }
}

impl SessionMachine {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn state(&self) -> SessionState {
        self.state
    }

    pub fn last_error(&self) -> Option<RuntimeErrorCode> {
        self.last_error
    }

    pub fn is_recording(&self) -> bool {
        matches!(self.state, SessionState::Recording(_))
    }

    pub fn apply(&mut self, event: DomainEvent) -> Result<ApplyResult, DomainError> {
        match (self.state, event) {
            (SessionState::Idle, DomainEvent::TogglePressed) => {
                self.start_recording(RecordingOrigin::Toggle);
                Ok(ApplyResult::Transitioned)
            }
            (SessionState::Idle, DomainEvent::HoldPressed) => {
                self.start_recording(RecordingOrigin::Hold);
                Ok(ApplyResult::Transitioned)
            }
            (SessionState::Idle, DomainEvent::ManualPressed) => {
                self.start_recording(RecordingOrigin::Manual);
                Ok(ApplyResult::Transitioned)
            }
            (SessionState::Idle, DomainEvent::Reset) => Ok(ApplyResult::Noop),

            (SessionState::Recording(recording), DomainEvent::TogglePressed) => {
                self.request_stop(recording);
                Ok(ApplyResult::Noop)
            }
            (SessionState::Recording(_), DomainEvent::HoldPressed) => Ok(ApplyResult::Noop),
            (SessionState::Recording(_), DomainEvent::ManualPressed) => Ok(ApplyResult::Noop),
            (SessionState::Recording(recording), DomainEvent::HoldReleased) => {
                if recording.origin == RecordingOrigin::Hold {
                    self.request_stop(recording);
                }
                Ok(ApplyResult::Noop)
            }
            (SessionState::Recording(recording), DomainEvent::MaxDurationReached) => {
                self.request_stop(recording);
                Ok(ApplyResult::Noop)
            }
            (SessionState::Recording(_), DomainEvent::RecordingStopped) => {
                self.state = SessionState::Transcribing;
                Ok(ApplyResult::Transitioned)
            }
            (SessionState::Recording(_), DomainEvent::RecordingFailed) => {
                self.state = SessionState::Error;
                self.last_error = Some(RuntimeErrorCode::AudioCaptureFailed);
                Ok(ApplyResult::Transitioned)
            }
            (SessionState::Recording(_), DomainEvent::Reset) => {
                self.state = SessionState::Idle;
                self.last_error = None;
                Ok(ApplyResult::Transitioned)
            }

            (SessionState::Transcribing, DomainEvent::TranscriptionSucceeded) => {
                self.state = SessionState::Outputting;
                Ok(ApplyResult::Transitioned)
            }
            (SessionState::Transcribing, DomainEvent::TranscriptionFailed) => {
                self.state = SessionState::Error;
                self.last_error = Some(RuntimeErrorCode::TranscriptionFailed);
                Ok(ApplyResult::Transitioned)
            }
            (SessionState::Transcribing, DomainEvent::Reset) => {
                self.state = SessionState::Idle;
                self.last_error = None;
                Ok(ApplyResult::Transitioned)
            }

            (SessionState::Outputting, DomainEvent::OutputCompleted) => {
                self.state = SessionState::Idle;
                self.last_error = None;
                Ok(ApplyResult::Transitioned)
            }
            (SessionState::Outputting, DomainEvent::OutputFailed) => {
                self.state = SessionState::Error;
                self.last_error = Some(RuntimeErrorCode::OutputFailed);
                Ok(ApplyResult::Transitioned)
            }
            (SessionState::Outputting, DomainEvent::Reset) => {
                self.state = SessionState::Idle;
                self.last_error = None;
                Ok(ApplyResult::Transitioned)
            }

            (SessionState::Error, DomainEvent::Reset) => {
                self.state = SessionState::Idle;
                self.last_error = None;
                Ok(ApplyResult::Transitioned)
            }

            (state, event) => Err(DomainError::InvalidTransition {
                state: state.tag(),
                event: event.tag(),
            }),
        }
    }

    fn start_recording(&mut self, origin: RecordingOrigin) {
        self.state = SessionState::Recording(RecordingState {
            origin,
            stop_requested: false,
        });
        self.last_error = None;
    }

    fn request_stop(&mut self, recording: RecordingState) {
        if recording.stop_requested {
            return;
        }

        self.state = SessionState::Recording(RecordingState {
            stop_requested: true,
            ..recording
        });
    }
}

impl SessionState {
    fn tag(self) -> SessionStateTag {
        match self {
            Self::Idle => SessionStateTag::Idle,
            Self::Recording(_) => SessionStateTag::Recording,
            Self::Transcribing => SessionStateTag::Transcribing,
            Self::Outputting => SessionStateTag::Outputting,
            Self::Error => SessionStateTag::Error,
        }
    }
}

impl DomainEvent {
    fn tag(self) -> DomainEventTag {
        match self {
            Self::TogglePressed => DomainEventTag::TogglePressed,
            Self::HoldPressed => DomainEventTag::HoldPressed,
            Self::ManualPressed => DomainEventTag::ManualPressed,
            Self::HoldReleased => DomainEventTag::HoldReleased,
            Self::MaxDurationReached => DomainEventTag::MaxDurationReached,
            Self::RecordingStopped => DomainEventTag::RecordingStopped,
            Self::RecordingFailed => DomainEventTag::RecordingFailed,
            Self::TranscriptionSucceeded => DomainEventTag::TranscriptionSucceeded,
            Self::TranscriptionFailed => DomainEventTag::TranscriptionFailed,
            Self::OutputCompleted => DomainEventTag::OutputCompleted,
            Self::OutputFailed => DomainEventTag::OutputFailed,
            Self::Reset => DomainEventTag::Reset,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        ApplyResult, DomainError, DomainEvent, RecordingOrigin, RecordingState, RuntimeErrorCode,
        SessionMachine, SessionState, SessionStateTag,
    };

    #[test]
    fn toggle_press_starts_recording_from_idle() {
        let mut machine = SessionMachine::new();

        let result = machine.apply(DomainEvent::TogglePressed);
        assert_eq!(result, Ok(ApplyResult::Transitioned));
        assert_eq!(
            machine.state(),
            SessionState::Recording(RecordingState {
                origin: RecordingOrigin::Toggle,
                stop_requested: false,
            })
        );
        assert!(machine.is_recording());
    }

    #[test]
    fn hold_press_starts_recording_from_idle() {
        let mut machine = SessionMachine::new();

        let result = machine.apply(DomainEvent::HoldPressed);
        assert_eq!(result, Ok(ApplyResult::Transitioned));
        assert_eq!(
            machine.state(),
            SessionState::Recording(RecordingState {
                origin: RecordingOrigin::Hold,
                stop_requested: false,
            })
        );
    }

    #[test]
    fn manual_start_starts_recording_from_idle() {
        let mut machine = SessionMachine::new();

        let result = machine.apply(DomainEvent::ManualPressed);
        assert_eq!(result, Ok(ApplyResult::Transitioned));
        assert_eq!(
            machine.state(),
            SessionState::Recording(RecordingState {
                origin: RecordingOrigin::Manual,
                stop_requested: false,
            })
        );
    }

    #[test]
    fn toggle_press_requests_stop_idempotently() {
        let mut machine = SessionMachine::new();
        let _ = machine.apply(DomainEvent::TogglePressed);

        let first = machine.apply(DomainEvent::TogglePressed);
        let second = machine.apply(DomainEvent::TogglePressed);

        assert_eq!(first, Ok(ApplyResult::Noop));
        assert_eq!(second, Ok(ApplyResult::Noop));
        assert_eq!(
            machine.state(),
            SessionState::Recording(RecordingState {
                origin: RecordingOrigin::Toggle,
                stop_requested: true,
            })
        );
    }

    #[test]
    fn hold_release_requests_stop_only_for_hold_origin() {
        let mut hold_machine = SessionMachine::new();
        let _ = hold_machine.apply(DomainEvent::HoldPressed);
        let hold_release = hold_machine.apply(DomainEvent::HoldReleased);
        assert_eq!(hold_release, Ok(ApplyResult::Noop));
        assert_eq!(
            hold_machine.state(),
            SessionState::Recording(RecordingState {
                origin: RecordingOrigin::Hold,
                stop_requested: true,
            })
        );

        let mut toggle_machine = SessionMachine::new();
        let _ = toggle_machine.apply(DomainEvent::TogglePressed);
        let toggle_release = toggle_machine.apply(DomainEvent::HoldReleased);
        assert_eq!(toggle_release, Ok(ApplyResult::Noop));
        assert_eq!(
            toggle_machine.state(),
            SessionState::Recording(RecordingState {
                origin: RecordingOrigin::Toggle,
                stop_requested: false,
            })
        );
    }

    #[test]
    fn max_duration_requests_stop() {
        let mut machine = SessionMachine::new();
        let _ = machine.apply(DomainEvent::HoldPressed);

        let result = machine.apply(DomainEvent::MaxDurationReached);
        assert_eq!(result, Ok(ApplyResult::Noop));
        assert_eq!(
            machine.state(),
            SessionState::Recording(RecordingState {
                origin: RecordingOrigin::Hold,
                stop_requested: true,
            })
        );
    }

    #[test]
    fn success_flow_reaches_idle() {
        let mut machine = SessionMachine::new();

        let _ = machine.apply(DomainEvent::TogglePressed);
        let _ = machine.apply(DomainEvent::TogglePressed);
        let to_transcribing = machine.apply(DomainEvent::RecordingStopped);
        assert_eq!(to_transcribing, Ok(ApplyResult::Transitioned));
        assert_eq!(machine.state(), SessionState::Transcribing);

        let to_outputting = machine.apply(DomainEvent::TranscriptionSucceeded);
        assert_eq!(to_outputting, Ok(ApplyResult::Transitioned));
        assert_eq!(machine.state(), SessionState::Outputting);

        let to_idle = machine.apply(DomainEvent::OutputCompleted);
        assert_eq!(to_idle, Ok(ApplyResult::Transitioned));
        assert_eq!(machine.state(), SessionState::Idle);
        assert_eq!(machine.last_error(), None);
    }

    #[test]
    fn failure_paths_enter_error_and_reset_to_idle() {
        let mut machine = SessionMachine::new();

        let _ = machine.apply(DomainEvent::TogglePressed);
        let record_failed = machine.apply(DomainEvent::RecordingFailed);
        assert_eq!(record_failed, Ok(ApplyResult::Transitioned));
        assert_eq!(machine.state(), SessionState::Error);
        assert_eq!(
            machine.last_error(),
            Some(RuntimeErrorCode::AudioCaptureFailed)
        );

        let reset = machine.apply(DomainEvent::Reset);
        assert_eq!(reset, Ok(ApplyResult::Transitioned));
        assert_eq!(machine.state(), SessionState::Idle);
        assert_eq!(machine.last_error(), None);
    }

    #[test]
    fn invalid_transition_returns_error() {
        let mut machine = SessionMachine::new();

        let result = machine.apply(DomainEvent::TranscriptionSucceeded);

        assert_eq!(
            result,
            Err(DomainError::InvalidTransition {
                state: SessionStateTag::Idle,
                event: super::DomainEventTag::TranscriptionSucceeded,
            })
        );
    }
}
