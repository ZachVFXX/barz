const std = @import("std");

pub inline fn readAt0(io: std.Io, file: std.Io.File, buf: []u8) ![]const u8 {
    const n = try file.readPositional(io, &.{buf}, 0);
    return buf[0..n];
}

pub inline fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \n");
}

pub inline fn openRo(io: std.Io, path: []const u8) !std.Io.File {
    return std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_only });
}
