const std = @import("std");

pub const Level = struct { percent: u16, muted: bool };

/// target: "@DEFAULT_AUDIO_SINK@" or "@DEFAULT_AUDIO_SOURCE@"
pub fn query(io: std.Io, gpa: std.mem.Allocator, target: []const u8) !Level {
    const res = try std.process.run(gpa, io, .{
        .argv = &.{ "wpctl", "get-volume", target },
    });

    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    // Output looks like "Volume: 0.45" or "Volume: 0.45 [MUTED]"
    var it = std.mem.tokenizeAny(u8, res.stdout, " \n");

    _ = it.next(); // "Volume:"

    const v = std.fmt.parseFloat(f32, it.next() orelse return error.BadOutput) catch return error.BadOutput;

    return .{
        .percent = @intFromFloat(@min(1000, @round(v * 100))),
        .muted = std.mem.indexOf(u8, res.stdout, "[MUTED]") != null,
    };
}
