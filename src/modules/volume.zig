const std = @import("std");
const wpctl = @import("utils/wpctl.zig");

const Self = @This();

pub const interval = 1;
pub const Data = wpctl.Level;

gpa: std.mem.Allocator,
cached_data: ?Data = null,

pub fn init(_: std.Io, gpa: std.mem.Allocator) !Self {
    return .{ .gpa = gpa };
}

pub fn deinit(_: *Self, _: std.Io) void {}

fn read(self: *Self, io: std.Io) !Data {
    return wpctl.query(io, self.gpa, "@DEFAULT_AUDIO_SINK@");
}

pub fn poll(self: *Self, io: std.Io, tick: u64) ?Data {
    if (self.cached_data == null or tick % interval == 0) {
        self.cached_data = self.read(io) catch null;
    }
    return self.cached_data;
}
