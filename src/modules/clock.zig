const std = @import("std");
const utils = @import("../utils.zig");

const Self = @This();

pub const Data = struct {
    year: u16,
    month: u8, // 1-12
    day: u8, // 1-31
    hour: u8,
    minute: u8,
    second: u8,
    utc_offset: i32, // seconds
};
interval: std.Io.Duration,
tz: std.tz.Tz,

pub fn init(io: std.Io, gpa: std.mem.Allocator, interval: std.Io.Duration) !Self {
    const f = try utils.openRo(io, "/etc/localtime");
    defer f.close(io);
    const buf: []u8 = try gpa.alloc(u8, 16 * 1024);
    defer gpa.free(buf);
    var r = std.Io.Reader.fixed(try utils.readAt0(io, f, buf));
    return .{ .tz = try std.tz.Tz.parse(gpa, &r), .interval = interval };
}

pub fn deinit(self: *Self, _: std.Io) void {
    self.tz.deinit();
}

pub fn read(self: *Self, io: std.Io) !Data {
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
