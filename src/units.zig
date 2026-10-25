const std = @import("std");

pub const Unit = enum {
    b,
    // decimal (base 1000)
    kb,
    mb,
    gb,
    tb,
    // binary (base 1024)
    kib,
    mib,
    gib,
    tib,

    /// number of byte for each units
    pub fn bytes(self: Unit) f64 {
        return switch (self) {
            .b => 1,
            .kb => 1e3,
            .mb => 1e6,
            .gb => 1e9,
            .tb => 1e12,
            .kib => 1024,
            .mib => 1024 * 1024,
            .gib => 1024 * 1024 * 1024,
            .tib => 1024 * 1024 * 1024 * 1024,
        };
    }
};

pub const Size = struct {
    total_bytes: f64 = 0,

    pub fn to(self: Size, unit: Unit) f64 {
        return self.total_bytes / unit.bytes();
    }
};

/// Accepts any integer or float type
pub fn from(value: anytype, unit: Unit) Size {
    const v: f64 = switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        else => value, // float types coerce to f64
    };
    return .{ .total_bytes = v * unit.bytes() };
}
