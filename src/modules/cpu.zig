const std = @import("std");
const utils = @import("../utils.zig");
const builtin = @import("builtin");
const Self = @This();

pub const Data = struct {
    percent: f32,
};
interval: std.Io.Duration,
file: std.Io.File,
buf: [256]u8 = undefined,
prev_idle: u64 = 0,
prev_total: u64 = 0,

pub fn init(io: std.Io, _: std.mem.Allocator, interval: std.Io.Duration) !Self {
    return .{ .file = try utils.openRo(io, "/proc/stat"), .interval = interval };
}

pub fn deinit(self: *Self, io: std.Io) void {
    self.file.close(io);
}

pub fn read(self: *Self, io: std.Io) !Data {
    const s = try utils.readAt0(io, self.file, &self.buf);
    var it = std.mem.tokenizeScalar(u8, s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len], ' ');
    _ = it.next();

    var total: u64 = 0;
    var idle: u64 = 0;
    var col: usize = 0;
    while (it.next()) |tok| : (col += 1) {
        const v = std.fmt.parseInt(u64, tok, 10) catch 0;
        total += v;
        if (col == 3 or col == 4) idle += v;
    }

    const dt: f32 = @floatFromInt(total - self.prev_total);
    const di: f32 = @floatFromInt(idle - self.prev_idle);
    const pct: f32 = if (self.prev_total != 0 and dt != 0) 100.0 * (1.0 - di / dt) else 0.0;
    self.prev_total = total;
    self.prev_idle = idle;
    return .{ .percent = pct };
}
