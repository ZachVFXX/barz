const std = @import("std");
const utils = @import("../utils.zig");

const Self = @This();

pub const interval = 1;
pub const Data = struct { percent: u8 };

file: std.Io.File,
max: u32,
buf: [16]u8 = undefined,
cached_data: ?Data = null,

/// Find the name of your backlight in /sys/class/backlight/... ex: intel_backlight, amdgpu_bl0, amdgpu_bl1, nvidia_0, acpi_video0..
pub fn init(io: std.Io, _: std.mem.Allocator, name: []const u8) !Self {
    var p1: [96]u8 = undefined;
    var p2: [96]u8 = undefined;

    const cur_path = std.fmt.bufPrint(&p1, "/sys/class/backlight/{s}/brightness", .{name}) catch return error.InvalidBacklight;
    const max_path = std.fmt.bufPrint(&p2, "/sys/class/backlight/{s}/max_brightness", .{name}) catch return error.InvalidBacklight;

    const file = utils.openRo(io, cur_path) catch return error.NoBacklight;
    const max_file = utils.openRo(io, max_path) catch {
        file.close(io);
        return error.InvalidBacklight;
    };
    defer max_file.close(io);

    var b: [16]u8 = undefined;
    const max = std.fmt.parseInt(u32, utils.trimmed(utils.readAt0(io, max_file, &b) catch ""), 10) catch 0;
    if (max == 0) {
        file.close(io);
        return error.InvalidBacklight;
    }
    return .{ .file = file, .max = max };
}

pub fn deinit(self: *Self, io: std.Io) void {
    self.file.close(io);
}

fn read(self: *Self, io: std.Io) !Data {
    const cur = try std.fmt.parseInt(u32, utils.trimmed(try utils.readAt0(io, self.file, &self.buf)), 10);
    return .{ .percent = @intCast(@min(100, @as(u64, cur) * 100 / self.max)) };
}

pub fn poll(self: *Self, io: std.Io, tick: u64) ?Data {
    if (self.cached_data == null or tick % interval == 0) {
        self.cached_data = self.read(io) catch null;
    }
    return self.cached_data;
}
