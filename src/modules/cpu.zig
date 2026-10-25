const std = @import("std");
const utils = @import("../utils.zig");
const builtin = @import("builtin");
const Self = @This();

pub const interval = 1;
pub const Data = struct {
    percent: f32,
};

file: std.Io.File,
buf: [256]u8 = undefined,
prev_idle: u64 = 0,
prev_total: u64 = 0,

cached_data: ?Data = null,

pub fn init(io: std.Io, _: std.mem.Allocator) !Self {
    return .{ .file = try utils.openRo(io, "/proc/stat") };
}

pub fn deinit(self: *Self, io: std.Io) void {
    self.file.close(io);
}

fn read(self: *Self, io: std.Io) !Data {
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

/// Re-reads when due (or if there is no data yet), then returns the cached data.
pub fn poll(self: *Self, io: std.Io, tick: u64) ?Data {
    if (self.cached_data == null or tick % interval == 0) {
        self.cached_data = self.read(io) catch null;
    }
    return self.cached_data;
}
