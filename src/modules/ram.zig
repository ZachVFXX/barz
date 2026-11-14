const std = @import("std");
const utils = @import("../utils.zig");
const units = @import("../units.zig");
const Self = @This();

pub const Data = struct {
    total: units.Size = .{},
    available: units.Size = .{},
    used: units.Size = .{},
    percent: f64 = 0,
};

interval: std.Io.Duration,
file: std.Io.File,
buf: [1024]u8 = undefined,

pub fn init(io: std.Io, _: std.mem.Allocator, interval: std.Io.Duration) !Self {
    return .{ .file = try utils.openRo(io, "/proc/meminfo"), .interval = interval };
}

pub fn deinit(self: *Self, io: std.Io) void {
    self.file.close(io);
}

pub fn read(self: *Self, io: std.Io) !Data {
    var d: Data = .{};
    var lines = std.mem.splitScalar(u8, try utils.readAt0(io, self.file, &self.buf), '\n');

    var total_kib: u64 = 0;
    var available_kib: u64 = 0;
    var used_kib: u64 = 0;

    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "MemTotal:")) total_kib = kb(l);
        if (std.mem.startsWith(u8, l, "MemAvailable:")) available_kib = kb(l);
    }
    used_kib = total_kib -| available_kib;

    d.available = units.from(available_kib, .kib);
    d.total = units.from(available_kib, .kib);
    d.used = units.from(used_kib, .kib);
    d.percent = @as(f64, @floatFromInt(used_kib)) / @as(f64, @floatFromInt(total_kib)) * 100.0;
    return d;
}

fn kb(line: []const u8) u64 {
    var it = std.mem.tokenizeAny(u8, line, " \t:");
    _ = it.next();
    return std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
}
