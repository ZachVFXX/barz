const std = @import("std");
const utils = @import("../utils.zig");

const Self = @This();

pub const interval = 1;

pub const Status = enum { charging, discharging, full, unknown };
pub const Data = struct { percent: u8, status: Status };

cap: std.Io.File,
status: std.Io.File,

cached_data: ?Data = null,

pub fn init(io: std.Io, _: std.mem.Allocator) !Self {
    const cap = try utils.openRo(io, "/sys/class/power_supply/BAT0/capacity");
    errdefer cap.close(io);
    return .{ .cap = cap, .status = try utils.openRo(io, "/sys/class/power_supply/BAT0/status") };
}

pub fn deinit(self: *Self, io: std.Io) void {
    self.cap.close(io);
    self.status.close(io);
}

fn read(self: *Self, io: std.Io) !Data {
    var cap_buf: [8]u8 = undefined;
    var st_buf: [16]u8 = undefined;

    const pct = std.fmt.parseInt(u8, utils.trimmed(try utils.readAt0(io, self.cap, &cap_buf)), 10) catch 0;
    const st = utils.trimmed(try utils.readAt0(io, self.status, &st_buf));

    return .{
        .percent = pct,
        .status = if (std.mem.eql(u8, st, "Charging")) .charging //
        else if (std.mem.eql(u8, st, "Discharging")) .discharging //
        else if (std.mem.eql(u8, st, "Full")) .full //
        else .unknown,
    };
}

/// Re-reads when due (or if there is no data yet), then returns the cached data.
pub fn poll(self: *Self, io: std.Io, tick: u64) ?Data {
    if (self.cached_data == null or tick % interval == 0) {
        self.cached_data = self.read(io) catch null;
    }
    return self.cached_data;
}
