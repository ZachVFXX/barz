const std = @import("std");
const utils = @import("../utils.zig");

const Self = @This();

pub const interval = 1;
pub const Data = struct {
    year: u16,
    month: u8, // 1-12
    day: u8, // 1-31
    hour: u8,
    minute: u8,
    second: u8,
    utc_offset: i32, // seconds
};

tz: std.tz.Tz,
cached_data: ?Data = null,

pub fn init(io: std.Io, gpa: std.mem.Allocator) !Self {
    const f = try utils.openRo(io, "/etc/localtime");
    defer f.close(io);
    var buf: [16 * 1024]u8 = undefined;
    var r = std.Io.Reader.fixed(try utils.readAt0(io, f, &buf));
    return .{ .tz = try std.tz.Tz.parse(gpa, &r) };
}

pub fn deinit(self: *Self, _: std.Io) void {
    self.tz.deinit();
}

fn read(self: *Self, io: std.Io) !Data {
    const utc: i64 = @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));

    var off: i32 = if (self.tz.timetypes.len > 0) self.tz.timetypes[0].offset else 0;
    for (self.tz.transitions) |tr| {
        if (tr.ts > utc) break;
        off = tr.timetype.offset;
    }

    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(utc + off) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return .{
        .year = yd.year,
        .month = md.month.numeric(),
        .day = md.day_index + 1,
        .hour = ds.getHoursIntoDay(),
        .minute = ds.getMinutesIntoHour(),
        .second = ds.getSecondsIntoMinute(),
        .utc_offset = off,
    };
}

/// Re-reads when due (or if there is no data yet), then returns the cached data.
pub fn poll(self: *Self, io: std.Io, tick: u64) ?Data {
    if (self.cached_data == null or tick % interval == 0) {
        self.cached_data = self.read(io) catch null;
    }
    return self.cached_data;
}
