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

    pub fn name(self: Unit) []const u8 {
        return switch (self) {
            .b => "B",
            .kb => "KB",
            .mb => "MB",
            .gb => "GB",
            .tb => "TB",
            .kib => "KiB",
            .mib => "MiB",
            .gib => "GiB",
            .tib => "TiB",
        };
    }
};

pub const System = enum {
    /// TB, GB, MB, KB
    si,
    /// TiB, Gib, Mib, KiB
    iec,
};

pub const Size = struct {
    bytes: f64 = 0,

    pub fn to(self: Size, unit: Unit) f64 {
        return self.bytes / unit.bytes();
    }

    pub fn humanize(self: Size, system: System) struct {
        value: f64,
        unit: Unit,
    } {
        const units = switch (system) {
            .si => [_]Unit{ .tb, .gb, .mb, .kb },
            .iec => [_]Unit{ .tib, .gib, .mib, .kib },
        };

        for (units) |unit| {
            const value = self.to(unit);
            if (value >= 1) {
                return .{ .value = value, .unit = unit };
            }
        }

        return .{ .value = self.bytes, .unit = .b };
    }
};

/// Accepts any integer or float type
pub fn from(value: anytype, unit: Unit) Size {
    const v: f64 = switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => value, // float types coerce to f64
        else => @compileError("Invalid float or int type"),
    };
    return .{ .bytes = v * unit.bytes() };
}
