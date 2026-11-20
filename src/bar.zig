const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const Bar = @This();

const max_scheduling_state = 16;
const data_cap = 128;
const max_events = 8;
const max_name = 32;

pub const Button = enum(u8) {
    left = 1,
    middle = 2,
    right = 3,
    scroll_up = 4,
    scroll_down = 5,
    _,
};

pub const Style = struct {
    color: ?[]const u8 = null,
    background: ?[]const u8 = null,
    urgent: bool = false,
};

const Block = struct {
    name: []const u8,
    full_text: []const u8,
    color: ?[]const u8 = null,
    background: ?[]const u8 = null,
    urgent: ?bool = null,
};

const RawEvent = struct {
    name: []const u8 = "",
    button: u8 = 0,
};

const Event = struct {
    name_buf: [max_name]u8 = undefined,
    name_len: u8 = 0,
    button: Button = .left,

    fn name(self: *const Event) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

const SchedulingState = struct {
    key: usize,
    valid: bool = false,
    next_due: i96 = 0,
    data: [data_cap]u8 align(16) = undefined,
};

io: Io,

output_buffer: []u8,
len: usize = 0,
blocks: usize = 0,
started: bool = false,

scheduling_states: [max_scheduling_state]SchedulingState = undefined,
n_scheduling_states: usize = 0,

now: i96 = 0,
wake: i96 = std.math.maxInt(i96),
dirty: bool = true,

events: [max_events]Event = undefined,
n_events: usize = 0,
in_buf: [512]u8 = undefined,
in_len: usize = 0,
stdin_open: bool = true,

pub fn init(io: Io, output_buffer: []u8) Bar {
    std.debug.assert(output_buffer.len > 16);
    return .{ .io = io, .output_buffer = output_buffer };
}

pub fn begin(self: *Bar) void {
    if (!self.started) {
        self.started = true;
        self.write("{\"version\":1,\"click_events\":true}\n[\n");
    }
    self.output_buffer[0] = '[';
    self.len = 1;
    self.blocks = 0;
    self.now = nowNs(self.io);
    self.wake = std.math.maxInt(i96);
}

pub fn get(self: *Bar, module: anytype) ?@TypeOf(module.*).Data {
    const M = @TypeOf(module.*);
    const D = ?M.Data;
    comptime std.debug.assert(@sizeOf(D) <= data_cap and @alignOf(D) <= 16);

    const state = self.schedulingStateFor(@intFromPtr(module));
    const cached: *D = @ptrCast(&state.data);

    if (!state.valid or state.next_due <= self.now) {
        const fresh: D = module.read(self.io) catch null;

        if (!state.valid or !std.meta.eql(fresh, cached.*)) {
            cached.* = fresh;
            self.dirty = true;
        }

        const step = module.interval.nanoseconds;
        state.next_due = if (state.valid) state.next_due + step else self.now + step;
        if (state.next_due <= self.now) state.next_due = self.now + step;
        state.valid = true;
    }

    self.wake = @min(self.wake, state.next_due);
    return cached.*;
}

pub fn item(self: *Bar, name: []const u8, style: Style, comptime fmt: []const u8, args: anytype) void {
    var tmp: [256]u8 = undefined;
    var tw = Io.Writer.fixed(&tmp);
    tw.print(fmt, args) catch return;

    var w = Io.Writer.fixed(self.output_buffer[self.len .. self.output_buffer.len - 3]);
    if (self.blocks > 0) w.writeAll(",") catch return;
    std.json.Stringify.value(Block{
        .name = name,
        .full_text = tw.buffered(),
        .color = style.color,
        .background = style.background,
        .urgent = if (style.urgent) true else null,
    }, .{ .emit_null_optional_fields = false }, &w) catch return;

    self.len += w.buffered().len;
    self.blocks += 1;
}

pub fn event(self: *Bar, name: []const u8) ?Button {
    for (self.events[0..self.n_events], 0..) |*e, i| {
        if (!std.mem.eql(u8, e.name(), name)) continue;
        const button = e.button;
        std.mem.copyForwards(Event, self.events[i .. self.n_events - 1], self.events[i + 1 .. self.n_events]);
        self.n_events -= 1;
        return button;
    }
    return null;
}

pub fn end(self: *Bar) void {
    if (self.dirty) {
        self.dirty = false;
        @memcpy(self.output_buffer[self.len..][0..3], "],\n");
        self.write(self.output_buffer[0 .. self.len + 3]);
    }

    self.n_events = 0;

    const wait = @max(0, @min(self.wake - nowNs(self.io), 3600 * std.time.ns_per_s));

    if (self.stdin_open) {
        if (waitStdin(wait)) {
            self.readEvents();
            if (self.n_events > 0) self.dirty = true;
        }
    } else if (wait > 0) {
        self.io.sleep(.{ .nanoseconds = wait }, .awake) catch {};
    }
}

fn write(self: *Bar, bytes: []const u8) void {
    Io.File.stdout().writeStreamingAll(self.io, bytes) catch {};
}

fn waitStdin(timeout_ns: i96) bool {
    var fds = [1]linux.pollfd{.{ .fd = 0, .events = linux.POLL.IN, .revents = 0 }};
    var ts: linux.timespec = .{
        .sec = @intCast(@divTrunc(timeout_ns, std.time.ns_per_s)),
        .nsec = @intCast(@mod(timeout_ns, std.time.ns_per_s)),
    };
    const rc: isize = @bitCast(linux.ppoll(&fds, 1, &ts, null));
    return rc > 0 and (fds[0].revents & (linux.POLL.IN | linux.POLL.HUP)) != 0;
}

fn readEvents(self: *Bar) void {
    const free = self.in_buf[self.in_len..];
    const rc: isize = @bitCast(linux.read(0, free.ptr, free.len));
    if (rc == 0) {
        self.stdin_open = false;
        return;
    }
    if (rc < 0) return;
    self.in_len += @intCast(rc);

    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, self.in_buf[0..self.in_len], start, '\n')) |nl| {
        self.parseEvent(self.in_buf[start..nl]);
        start = nl + 1;
    }

    const rest = self.in_len - start;
    std.mem.copyForwards(u8, self.in_buf[0..rest], self.in_buf[start..self.in_len]);
    self.in_len = rest;
    if (self.in_len == self.in_buf.len) self.in_len = 0;
}

fn parseEvent(self: *Bar, raw: []const u8) void {
    if (self.n_events == max_events) return;

    const line = std.mem.trim(u8, raw, " \t\r,");
    if (line.len == 0 or line[0] != '{') return;

    var scratch: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const parsed = std.json.parseFromSliceLeaky(RawEvent, fba.allocator(), line, .{
        .ignore_unknown_fields = true,
    }) catch return;

    if (parsed.name.len == 0 or parsed.name.len > max_name) return;

    const e = &self.events[self.n_events];
    @memcpy(e.name_buf[0..parsed.name.len], parsed.name);
    e.name_len = @intCast(parsed.name.len);
    e.button = @fromBackingInt(@intCast(parsed.button));
    self.n_events += 1;
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
