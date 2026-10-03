//! A tiny Rust fixture for the full grammar set.

/// The largest size a store holds.
pub const MAX_SIZE: usize = 64;

static GREETING: &str = "hello";

/// A key-value store.
#[derive(Debug, Clone)]
pub struct Store {
    /// The number of entries.
    len: usize,
}

/// Shape of a value.
pub enum Shape {
    Circle,
    Square { side: u32 },
}

/// Raw bits of a number.
#[repr(C)]
union Bits {
    int: u32,
    float: f32,
}

pub type Id = u64;

/// Something that can be stored.
pub trait Storable {
    /// The key this value is stored under.
    fn key(&self) -> String;
}

impl Store {
    /// The default capacity.
    pub const CAPACITY: usize = 8;

    /// Builds an empty store.
    pub fn new() -> Self {
        Store { len: 0 }
    }
}

impl<T: Clone> Storable for Wrapper<T> {
    fn key(&self) -> String {
        String::new()
    }
}

/// Inner helpers.
mod helpers {
    /// How many helpers there are.
    pub const COUNT: u8 = 1;

    static NAME: &str = "helpers";

    pub fn assist() {}
}

macro_rules! square {
    ($x:expr) => {
        $x * $x
    };
}

/// Adds two numbers.
#[inline]
#[must_use]
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}
