const std = @import("std");
const Io = std.Io;
const Bar = @This();

const max_scheduling_state = 16;
const data_cap = 128;

const SchedulingState = struct {
    /// Module adress use for key
    key: usize,
    /// False until the first read
    valid: bool = false,
    /// Nanoseconds
    next_due: i96 = 0,
    /// cached ?Module.Data store as bytes
    data: [data_cap]u8 align(16) = undefined,
};

io: Io,
separator: []const u8 = " | ",
is_tty: bool,

output_buffer: []u8,
len: usize = 0,

scheduling_states: [max_scheduling_state]SchedulingState = undefined,
n_scheduling_states: usize = 0,

/// monotonic ns
now: i96 = 0,
/// earliest deadline seen this frame
wake: i96 = std.math.maxInt(i96),
/// true so the first frame is drawn
dirty: bool = true,

pub fn init(io: Io, output_buffer: []u8) Bar {
    return .{
        .io = io,
        .output_buffer = output_buffer,
        .is_tty = (Io.File.stdout().isTty(io) catch false) and
            (Io.File.stdout().supportsAnsiEscapeCodes(io) catch false),
    };
}

pub fn begin(self: *Bar) void {
    self.len = 0;
    self.now = nowNs(self.io);
    self.wake = std.math.maxInt(i96);
}

/// Returns the module's data, calling `module.read(io)` only when its interval has elapsed
/// The module needs `pub const Data`, `interval: Io.Duration` and `read(*Self, Io) !Data`
pub fn get(self: *Bar, module: anytype) ?@TypeOf(module.*).Data {
    const M = @TypeOf(module.*);
    const D = ?M.Data;
    comptime std.debug.assert(@sizeOf(D) <= data_cap and @alignOf(D) <= 16);

    const scheduling_state = self.schedulingStateFor(@intFromPtr(module));
    const cached: *D = @ptrCast(&scheduling_state.data);

    if (!scheduling_state.valid or scheduling_state.next_due <= self.now) {
        const fresh: D = module.read(self.io) catch null;

        if (!scheduling_state.valid or !std.meta.eql(fresh, cached.*)) {
            cached.* = fresh;
            self.dirty = true;
        }

        const step = module.interval.nanoseconds;
        scheduling_state.next_due = if (scheduling_state.valid) scheduling_state.next_due + step else self.now + step;
        if (scheduling_state.next_due <= self.now) scheduling_state.next_due = self.now + step;
        scheduling_state.valid = true;
    }

    self.wake = @min(self.wake, scheduling_state.next_due);
    return cached.*;
}

/// Add a new item with a separator
pub fn item(self: *Bar, comptime fmt: []const u8, args: anytype) void {
    const start = self.len;
    var w = Io.Writer.fixed(self.output_buffer[start .. self.output_buffer.len - 1]);
    if (start > 0) w.writeAll(self.separator) catch return;
    w.print(fmt, args) catch return;
    self.len = start + w.buffered().len;
}

/// Writes the line if something changed
pub fn end(self: *Bar) void {
    if (self.dirty) {
        self.dirty = false;
        const out = Io.File.stdout();
        if (self.is_tty) {
            out.writeStreamingAll(self.io, "\r\x1b[2K") catch {};
            out.writeStreamingAll(self.io, self.output_buffer[0..self.len]) catch {};
        } else {
            self.output_buffer[self.len] = '\n'; // item() always leaves the last byte free
            out.writeStreamingAll(self.io, self.output_buffer[0 .. self.len + 1]) catch {};
        }
    }

    const wait = self.wake - nowNs(self.io);
    if (wait > 0) self.io.sleep(.{ .nanoseconds = wait }, .awake) catch {};
}

fn schedulingStateFor(self: *Bar, key: usize) *SchedulingState {
    for (self.scheduling_states[0..self.n_scheduling_states]) |*s| {
        if (s.key == key) return s;
    }
    std.debug.assert(self.n_scheduling_states < max_scheduling_state);
    const s = &self.scheduling_states[self.n_scheduling_states];
    self.n_scheduling_states += 1;
    s.* = .{ .key = key };
    return s;
}

fn nowNs(io: Io) i96 {
    return Io.Timestamp.now(io, .awake).nanoseconds;
}
