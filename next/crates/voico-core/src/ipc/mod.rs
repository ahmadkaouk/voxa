#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub struct ApiVersion {
    pub major: u16,
    pub minor: u16,
}

impl ApiVersion {
    pub const V1: Self = Self { major: 1, minor: 0 };
}
