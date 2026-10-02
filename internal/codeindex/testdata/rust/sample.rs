//! A tiny Rust fixture for the full grammar set.

/// The largest size a store holds.
pub const MAX_SIZE: usize = 64;

static GREETING: &str = "hello";

/// A key-value store.
pub struct Store {
    /// The number of entries.
    len: usize,
}

/// Shape of a value.
pub enum Shape {
    Circle,
    Square,
}

pub type Id = u64;

/// Something that can be stored.
pub trait Storable {
    /// The key this value is stored under.
    fn key(&self) -> String;
}

impl Store {
    /// Builds an empty store.
    pub fn new() -> Self {
        Store { len: 0 }
    }
}

/// Inner helpers.
mod helpers {
    pub fn assist() {}
}

macro_rules! square {
    ($x:expr) => {
        $x * $x
    };
}

/// Adds two numbers.
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}
