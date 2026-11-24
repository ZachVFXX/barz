const std = @import("std");
const utils = @import("../utils.zig");
const Self = @This();

pub const Data = struct { percent: u8 };

gpa: std.mem.Allocator,
interval: std.Io.Duration,
file: std.Io.File,
max: u32,
path: []u8,

pub fn init(io: std.Io, gpa: std.mem.Allocator, name: []const u8, interval: std.Io.Duration) !Self {
    const path = try std.fmt.allocPrint(gpa, "/sys/class/backlight/{s}/brightness", .{name});
    errdefer gpa.free(path);

    const max_path = try std.fmt.allocPrint(gpa, "/sys/class/backlight/{s}/max_brightness", .{name});
    defer gpa.free(max_path);

    const file = try utils.openRo(io, path);
    errdefer file.close(io);

    const max_file = try utils.openRo(io, max_path);
    defer max_file.close(io);

    const max = try readNumber(gpa, io, max_file);

    return .{
        .gpa = gpa,
        .interval = interval,
        .file = file,
        .max = max,
        .path = path,
    };
}

pub fn deinit(self: *Self, io: std.Io) void {
    self.file.close(io);
    self.gpa.free(self.path);
}

pub fn read(self: *Self, io: std.Io) !Data {
    const cur = try readNumber(self.gpa, io, self.file);
    return .{ .percent = @intCast(@min(100, @as(u64, cur) * 100 / self.max)) };
}

pub fn adjust(self: *Self, io: std.Io, delta: i32) !void {
    const cur = try readNumber(self.gpa, io, self.file);

    var step: i64 = @divTrunc(@as(i64, self.max) * delta, 100);
    if (step == 0) step = if (delta > 0) 1 else -1;

    const next: u32 = @intCast(std.math.clamp(@as(i64, cur) + step, 1, self.max));

    const text = try std.fmt.allocPrint(self.gpa, "{d}", .{next});
    defer self.gpa.free(text);

    const file = try utils.openRw(io, self.path);
    defer file.close(io);
    try file.writeStreamingAll(io, text);
}

fn readNumber(gpa: std.mem.Allocator, io: std.Io, file: std.Io.File) !u32 {
    const buf = try gpa.alloc(u8, 16);
    defer gpa.free(buf);
    return std.fmt.parseInt(u32, utils.trimmed(try utils.readAt0(io, file, buf)), 10);
}
