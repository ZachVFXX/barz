const std = @import("std");
const Io = std.Io;

const Bar = @This();

io: Io,
tick: u64 = 0,
separator: []const u8 = " | ",
update_rate: Io.Duration = .fromSeconds(1),
output_buffer: [512]u8 = undefined,
len: usize = 0,

is_tty: bool, // only emit escape codes on a terminal

pub fn init(io: Io) Bar {
    return .{
        .io = io,
        .is_tty = (Io.File.stdout().isTty(io) catch false) and (Io.File.stdout().supportsAnsiEscapeCodes(io) catch false),
    };
}

pub fn begin(self: *Bar) void {
    self.len = 0;
}

pub fn item(self: *Bar, comptime fmt: []const u8, args: anytype) void {
    const start = self.len;
    var w = Io.Writer.fixed(self.output_buffer[start .. self.output_buffer.len - 1]);
    if (start > 0) w.writeAll(self.separator) catch return;
    w.print(fmt, args) catch return;
    self.len = start + w.buffered().len;
}

pub fn end(self: *Bar) void {
    const out = Io.File.stdout();

    // Clear the previous line if one
    if (self.is_tty) {
        out.writeStreamingAll(self.io, "\x1b[2J\x1b[H") catch unreachable;
    }

    self.output_buffer[self.len] = '\n';
    out.writeStreamingAll(self.io, self.output_buffer[0 .. self.len + 1]) catch unreachable;
    self.io.sleep(self.update_rate, .real) catch unreachable;
    self.tick += 1;
}
