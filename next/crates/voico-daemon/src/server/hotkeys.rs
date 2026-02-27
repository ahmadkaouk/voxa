use std::sync::mpsc;
use std::thread;

use rdev::{EventType, Key, listen};

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub(super) enum HotkeyEventKind {
    Press,
    Release,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub(super) enum HotkeyKey {
    RightOption,
    Command,
    Space,
    Function,
    Other,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub(super) enum HotkeySignal {
    Activated,
    Deactivated,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub(super) enum ConfiguredHotkey {
    RightOption,
    Function,
    CmdSpace,
    Unsupported,
}

impl ConfiguredHotkey {
    pub(super) fn from_raw(raw: &str) -> Self {
        match raw {
            "right_option" => Self::RightOption,
            "fn" => Self::Function,
            "cmd_space" => Self::CmdSpace,
            _ => Self::Unsupported,
        }
    }
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub(super) struct HotkeyInputEvent {
    pub(super) kind: HotkeyEventKind,
    pub(super) key: HotkeyKey,
}

#[derive(Debug, Clone)]
pub(super) struct HotkeyMatcher {
    hotkey: ConfiguredHotkey,
    command_down: bool,
    right_option_down: bool,
    function_down: bool,
    space_down: bool,
}

impl HotkeyMatcher {
    pub(super) fn new(hotkey: ConfiguredHotkey) -> Self {
        Self {
            hotkey,
            command_down: false,
            right_option_down: false,
            function_down: false,
            space_down: false,
        }
    }

    pub(super) fn on_event(
        &mut self,
        kind: HotkeyEventKind,
        key: HotkeyKey,
    ) -> Option<HotkeySignal> {
        match kind {
            HotkeyEventKind::Press => self.on_press(key),
            HotkeyEventKind::Release => self.on_release(key),
        }
    }

    fn on_press(&mut self, key: HotkeyKey) -> Option<HotkeySignal> {
        match key {
            HotkeyKey::Command => {
                self.command_down = true;
                None
            }
            HotkeyKey::RightOption => {
                let first_press = !self.right_option_down;
                self.right_option_down = true;
                if first_press && matches!(self.hotkey, ConfiguredHotkey::RightOption) {
                    Some(HotkeySignal::Activated)
                } else {
                    None
                }
            }
            HotkeyKey::Function => {
                let first_press = !self.function_down;
                self.function_down = true;
                if first_press && matches!(self.hotkey, ConfiguredHotkey::Function) {
                    Some(HotkeySignal::Activated)
                } else {
                    None
                }
            }
            HotkeyKey::Space => {
                let first_press = !self.space_down;
                self.space_down = true;
                if first_press
                    && matches!(self.hotkey, ConfiguredHotkey::CmdSpace)
                    && self.command_down
                {
                    Some(HotkeySignal::Activated)
                } else {
                    None
                }
            }
            HotkeyKey::Other => None,
        }
    }

    fn on_release(&mut self, key: HotkeyKey) -> Option<HotkeySignal> {
        match key {
            HotkeyKey::Command => {
                let command_was_down = self.command_down;
                self.command_down = false;
                if matches!(self.hotkey, ConfiguredHotkey::CmdSpace)
                    && command_was_down
                    && self.space_down
                {
                    Some(HotkeySignal::Deactivated)
                } else {
                    None
                }
            }
            HotkeyKey::RightOption => {
                let was_down = self.right_option_down;
                self.right_option_down = false;
                if matches!(self.hotkey, ConfiguredHotkey::RightOption) && was_down {
                    Some(HotkeySignal::Deactivated)
                } else {
                    None
                }
            }
            HotkeyKey::Function => {
                let was_down = self.function_down;
                self.function_down = false;
                if matches!(self.hotkey, ConfiguredHotkey::Function) && was_down {
                    Some(HotkeySignal::Deactivated)
                } else {
                    None
                }
            }
            HotkeyKey::Space => {
                let was_down = self.space_down;
                self.space_down = false;
                if matches!(self.hotkey, ConfiguredHotkey::CmdSpace) && was_down {
                    Some(HotkeySignal::Deactivated)
                } else {
                    None
                }
            }
            HotkeyKey::Other => None,
        }
    }
}

pub(super) fn spawn_hotkey_event_listener(tx: mpsc::Sender<HotkeyInputEvent>) {
    thread::spawn(move || {
        let result = listen(move |event| {
            if let Some(mapped) = map_event(event.event_type) {
                let _ = tx.send(mapped);
            }
        });
        if let Err(err) = result {
            eprintln!("WARN HOTKEY_LISTENER_FAILED: {:?}", err);
        }
    });
}

fn map_event(event: EventType) -> Option<HotkeyInputEvent> {
    match event {
        EventType::KeyPress(key) => Some(HotkeyInputEvent {
            kind: HotkeyEventKind::Press,
            key: map_key(key),
        }),
        EventType::KeyRelease(key) => Some(HotkeyInputEvent {
            kind: HotkeyEventKind::Release,
            key: map_key(key),
        }),
        _ => None,
    }
}

fn map_key(key: Key) -> HotkeyKey {
    match key {
        Key::Alt | Key::AltGr => HotkeyKey::RightOption,
        Key::MetaLeft | Key::MetaRight => HotkeyKey::Command,
        Key::Space => HotkeyKey::Space,
        Key::Function => HotkeyKey::Function,
        _ => HotkeyKey::Other,
    }
}

#[cfg(test)]
mod tests {
    use super::{ConfiguredHotkey, HotkeyEventKind, HotkeyKey, HotkeyMatcher, HotkeySignal};

    #[test]
    fn right_option_triggers_once_until_release() {
        let mut matcher = HotkeyMatcher::new(ConfiguredHotkey::RightOption);

        assert_eq!(
            matcher.on_event(HotkeyEventKind::Press, HotkeyKey::RightOption),
            Some(HotkeySignal::Activated)
        );
        assert_eq!(
            matcher.on_event(HotkeyEventKind::Press, HotkeyKey::RightOption),
            None
        );
        assert_eq!(
            matcher.on_event(HotkeyEventKind::Release, HotkeyKey::RightOption),
            Some(HotkeySignal::Deactivated)
        );
    }

    #[test]
    fn function_triggers_once_until_release() {
        let mut matcher = HotkeyMatcher::new(ConfiguredHotkey::Function);

        assert_eq!(
            matcher.on_event(HotkeyEventKind::Press, HotkeyKey::Function),
            Some(HotkeySignal::Activated)
        );
        assert_eq!(
            matcher.on_event(HotkeyEventKind::Press, HotkeyKey::Function),
            None
        );
        assert_eq!(
            matcher.on_event(HotkeyEventKind::Release, HotkeyKey::Function),
            Some(HotkeySignal::Deactivated)
        );
    }

    #[test]
    fn cmd_space_requires_command_modifier() {
        let mut matcher = HotkeyMatcher::new(ConfiguredHotkey::CmdSpace);

        assert_eq!(
            matcher.on_event(HotkeyEventKind::Press, HotkeyKey::Space),
            None
        );
        assert_eq!(
            matcher.on_event(HotkeyEventKind::Release, HotkeyKey::Space),
            Some(HotkeySignal::Deactivated)
        );
        assert_eq!(
            matcher.on_event(HotkeyEventKind::Press, HotkeyKey::Command),
            None
        );
        assert_eq!(
            matcher.on_event(HotkeyEventKind::Press, HotkeyKey::Space),
            Some(HotkeySignal::Activated)
        );
        assert_eq!(
            matcher.on_event(HotkeyEventKind::Release, HotkeyKey::Space),
            Some(HotkeySignal::Deactivated)
        );
    }

    #[test]
    fn unsupported_hotkey_never_triggers() {
        let mut matcher = HotkeyMatcher::new(ConfiguredHotkey::Unsupported);

        assert_eq!(
            matcher.on_event(HotkeyEventKind::Press, HotkeyKey::RightOption),
            None
        );
        assert_eq!(
            matcher.on_event(HotkeyEventKind::Release, HotkeyKey::RightOption),
            None
        );
    }
}
