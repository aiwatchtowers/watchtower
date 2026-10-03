const std = @import("std");

/// The largest size a store holds.
pub const max_size: usize = 64;

var counter: u32 = 0;

/// A key-value store.
pub const Store = struct {
    len: usize,
    name: []const u8,

    /// The store's capacity.
    pub const capacity = 16;

    /// Builds an empty store.
    pub fn init(name: []const u8) Store {
        const local = name;
        return .{ .len = 0, .name = local };
    }

    pub fn add(self: *Store) void {
        self.len += 1;
    }
};

// Shapes a store draws.
pub const Shape = enum {
    circle,
    square,

    pub fn sides(self: Shape) u8 {
        return switch (self) {
            .circle => 0,
            .square => 4,
        };
    }
};

pub const Value = union(enum) {
    int: i64,
    text: []const u8,
};

pub const Failure = error{ Full, Empty };

/// Doubles a number.
fn twice(n: u32) u32 {
    return n * 2;
}

test "twice doubles" {
    try std.testing.expectEqual(@as(u32, 4), twice(2));
}
