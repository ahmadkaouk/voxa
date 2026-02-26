use crate::daemon_config::DaemonHotkey;

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum HotkeyEventKind {
    Press,
    Release,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum HotkeyKey {
    RightOption,
    Command,
    Space,
    Function,
    Other,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum HotkeySignal {
    Activated,
    Deactivated,
}

#[derive(Debug, Clone)]
pub struct HotkeyMatcher {
    hotkey: DaemonHotkey,
    command_down: bool,
    right_option_down: bool,
    function_down: bool,
    space_down: bool,
}

impl HotkeyMatcher {
    pub fn new(hotkey: DaemonHotkey) -> Self {
        Self {
            hotkey,
            command_down: false,
            right_option_down: false,
            function_down: false,
            space_down: false,
        }
    }

    pub fn on_event(&mut self, kind: HotkeyEventKind, key: HotkeyKey) -> Option<HotkeySignal> {
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
                if first_press && matches!(self.hotkey, DaemonHotkey::RightOption) {
                    Some(HotkeySignal::Activated)
                } else {
                    None
                }
            }
            HotkeyKey::Function => {
                let first_press = !self.function_down;
                self.function_down = true;
                if first_press && matches!(self.hotkey, DaemonHotkey::Fn) {
                    Some(HotkeySignal::Activated)
                } else {
                    None
                }
            }
            HotkeyKey::Space => {
                let first_press = !self.space_down;
                self.space_down = true;

                if first_press && matches!(self.hotkey, DaemonHotkey::CmdSpace) && self.command_down
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

                if matches!(self.hotkey, DaemonHotkey::CmdSpace)
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
                if matches!(self.hotkey, DaemonHotkey::RightOption) && was_down {
                    Some(HotkeySignal::Deactivated)
                } else {
                    None
                }
            }
            HotkeyKey::Function => {
                let was_down = self.function_down;
                self.function_down = false;
                if matches!(self.hotkey, DaemonHotkey::Fn) && was_down {
                    Some(HotkeySignal::Deactivated)
                } else {
                    None
                }
            }
            HotkeyKey::Space => {
                let was_down = self.space_down;
                self.space_down = false;
                if matches!(self.hotkey, DaemonHotkey::CmdSpace) && was_down {
                    Some(HotkeySignal::Deactivated)
                } else {
                    None
                }
            }
            HotkeyKey::Other => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{HotkeyEventKind, HotkeyKey, HotkeyMatcher, HotkeySignal};
    use crate::daemon_config::DaemonHotkey;

    #[test]
    fn right_option_triggers_once_until_release() {
        let mut matcher = HotkeyMatcher::new(DaemonHotkey::RightOption);

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
        assert_eq!(
            matcher.on_event(HotkeyEventKind::Press, HotkeyKey::RightOption),
            Some(HotkeySignal::Activated)
        );
    }

    #[test]
    fn function_triggers_once_until_release() {
        let mut matcher = HotkeyMatcher::new(DaemonHotkey::Fn);

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
        assert_eq!(
            matcher.on_event(HotkeyEventKind::Press, HotkeyKey::Function),
            Some(HotkeySignal::Activated)
        );
    }

    #[test]
    fn cmd_space_requires_command_modifier() {
        let mut matcher = HotkeyMatcher::new(DaemonHotkey::CmdSpace);

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
            matcher.on_event(HotkeyEventKind::Press, HotkeyKey::Space),
            None
        );
        assert_eq!(
            matcher.on_event(HotkeyEventKind::Release, HotkeyKey::Space),
            Some(HotkeySignal::Deactivated)
        );

        assert_eq!(
            matcher.on_event(HotkeyEventKind::Press, HotkeyKey::Space),
            Some(HotkeySignal::Activated)
        );
        assert_eq!(
            matcher.on_event(HotkeyEventKind::Release, HotkeyKey::Command),
            Some(HotkeySignal::Deactivated)
        );
    }

    #[test]
    fn unrelated_keys_never_trigger() {
        let mut matcher = HotkeyMatcher::new(DaemonHotkey::RightOption);

        assert_eq!(
            matcher.on_event(HotkeyEventKind::Press, HotkeyKey::Other),
            None
        );
        assert_eq!(
            matcher.on_event(HotkeyEventKind::Release, HotkeyKey::Other),
            None
        );
    }
}
