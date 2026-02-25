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

    pub fn on_event(&mut self, kind: HotkeyEventKind, key: HotkeyKey) -> bool {
        match kind {
            HotkeyEventKind::Press => self.on_press(key),
            HotkeyEventKind::Release => {
                self.on_release(key);
                false
            }
        }
    }

    fn on_press(&mut self, key: HotkeyKey) -> bool {
        match key {
            HotkeyKey::Command => {
                self.command_down = true;
                false
            }
            HotkeyKey::RightOption => {
                let first_press = !self.right_option_down;
                self.right_option_down = true;
                first_press && matches!(self.hotkey, DaemonHotkey::RightOption)
            }
            HotkeyKey::Function => {
                let first_press = !self.function_down;
                self.function_down = true;
                first_press && matches!(self.hotkey, DaemonHotkey::Fn)
            }
            HotkeyKey::Space => {
                let first_press = !self.space_down;
                self.space_down = true;

                first_press && matches!(self.hotkey, DaemonHotkey::CmdSpace) && self.command_down
            }
            HotkeyKey::Other => false,
        }
    }

    fn on_release(&mut self, key: HotkeyKey) {
        match key {
            HotkeyKey::Command => self.command_down = false,
            HotkeyKey::RightOption => self.right_option_down = false,
            HotkeyKey::Function => self.function_down = false,
            HotkeyKey::Space => self.space_down = false,
            HotkeyKey::Other => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{HotkeyEventKind, HotkeyKey, HotkeyMatcher};
    use crate::daemon_config::DaemonHotkey;

    #[test]
    fn right_option_triggers_once_until_release() {
        let mut matcher = HotkeyMatcher::new(DaemonHotkey::RightOption);

        assert!(matcher.on_event(HotkeyEventKind::Press, HotkeyKey::RightOption));
        assert!(!matcher.on_event(HotkeyEventKind::Press, HotkeyKey::RightOption));
        assert!(!matcher.on_event(HotkeyEventKind::Release, HotkeyKey::RightOption));
        assert!(matcher.on_event(HotkeyEventKind::Press, HotkeyKey::RightOption));
    }

    #[test]
    fn function_triggers_once_until_release() {
        let mut matcher = HotkeyMatcher::new(DaemonHotkey::Fn);

        assert!(matcher.on_event(HotkeyEventKind::Press, HotkeyKey::Function));
        assert!(!matcher.on_event(HotkeyEventKind::Press, HotkeyKey::Function));
        assert!(!matcher.on_event(HotkeyEventKind::Release, HotkeyKey::Function));
        assert!(matcher.on_event(HotkeyEventKind::Press, HotkeyKey::Function));
    }

    #[test]
    fn cmd_space_requires_command_modifier() {
        let mut matcher = HotkeyMatcher::new(DaemonHotkey::CmdSpace);

        assert!(!matcher.on_event(HotkeyEventKind::Press, HotkeyKey::Space));
        assert!(!matcher.on_event(HotkeyEventKind::Release, HotkeyKey::Space));

        assert!(!matcher.on_event(HotkeyEventKind::Press, HotkeyKey::Command));
        assert!(matcher.on_event(HotkeyEventKind::Press, HotkeyKey::Space));
        assert!(!matcher.on_event(HotkeyEventKind::Press, HotkeyKey::Space));
        assert!(!matcher.on_event(HotkeyEventKind::Release, HotkeyKey::Space));

        assert!(matcher.on_event(HotkeyEventKind::Press, HotkeyKey::Space));
        assert!(!matcher.on_event(HotkeyEventKind::Release, HotkeyKey::Command));
    }

    #[test]
    fn unrelated_keys_never_trigger() {
        let mut matcher = HotkeyMatcher::new(DaemonHotkey::RightOption);

        assert!(!matcher.on_event(HotkeyEventKind::Press, HotkeyKey::Other));
        assert!(!matcher.on_event(HotkeyEventKind::Release, HotkeyKey::Other));
    }
}
