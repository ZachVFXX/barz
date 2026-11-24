//! I3bar protocol: https://i3wm.org/docs/i3bar-protocol.html
const std = @import("std");

pub const Button = enum(u8) {
    left = 1,
    middle = 2,
    right = 3,
    scroll_up = 4,
    scroll_down = 5,
    _,
};

pub const Block = struct {
    /// Every block should have a unique name (string) entry so that it can be easily identified in scripts which process the output. i3bar completely ignores the name and instance fields...
    name: ?[]const u8 = null,
    /// Make sure to also specify an instance (string) entry where appropriate. For example, the user can have multiple disk space blocks for multiple mount points.
    instance: ?[]const u8 = null,
    /// The full_text will be displayed by i3bar on the status line. This is the only required key. If full_text is an empty string, the block will be skipped.
    full_text: []const u8,
    /// Where appropriate, the short_text (string) entry should also be provided. It will be used in case the status line needs to be shortened because it uses more space than your screen provides.
    short_text: ?[]const u8 = null,
    /// Colors are specified in hex (like in HTML), starting with a leading hash sign. For example, #ff0000 means red.
    color: ?[]const u8 = null,
    /// Overrides the background color for this particular block.
    background: ?[]const u8 = null,
    /// Overrides the border color for this particular block.
    border: ?[]const u8 = null,
    /// Defines the width (in pixels) of the top border of this block. Defaults to 1.
    border_top: ?i32 = null,
    /// Defines the width (in pixels) of the right border of this block. Defaults to 1.
    border_right: ?i32 = null,
    /// Defines the width (in pixels) of the bottom border of this block. Defaults to 1.
    border_bottom: ?i32 = null,
    /// Defines the width (in pixels) of the left border of this block. Defaults to 1.
    border_left: ?i32 = null,
    /// The minimum width of the block. A string means "the width of this text", which is font independent.
    min_width: ?[]const u8 = null,
    /// Align text on the center, right or left (default) of the block, when the minimum width of the latter, specified by the min_width key, is not reached.
    @"align": ?[]const u8 = null,
    /// A boolean which specifies whether the current value is urgent.
    urgent: ?bool = null,
    /// A boolean which specifies whether a separator line should be drawn after this block. The default is true.
    separator: ?bool = null,
    /// The amount of pixels to leave blank after the block. The default is 9 pixels.
    separator_block_width: ?i32 = null,
    /// Set to "pango" to use Pango markup. Set to "none" to not use any markup (default).
    markup: ?[]const u8 = null,
};

/// A click event sent by the bar on stdin.
pub const Event = struct {
    name: []const u8 = "",
    button: Button = .left,
};

pub const max_events = 8;

/// Fixed-capacity queue of click events.
pub const Events = struct {
    items: [max_events]Event = undefined,
    len: usize = 0,
    fba: std.heap.FixedBufferAllocator,

    /// `buffer` stores the event names, it must outlive the Events.
    pub fn init(buffer: []u8) Events {
        return .{ .fba = .init(buffer) };
    }

    /// Drops every pending event and frees all their names at once.
    /// Call once per frame after the events have been consumed.
    pub fn reset(self: *Events) void {
        self.len = 0;
        self.fba.reset();
    }

    pub fn parse(self: *Events, raw_json: []const u8) void {
        if (self.len == max_events) return;

        const line = std.mem.trim(u8, raw_json, " \t\r,");
        if (line.len == 0 or line[0] != '{') return;

        const event = std.json.parseFromSliceLeaky(Event, self.fba.allocator(), line, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return;

        if (event.name.len == 0) return;

        self.items[self.len] = event;
        self.len += 1;
    }

    /// Removes and returns the first pending click for the block `name`.
    pub fn take(self: *Events, name: []const u8) ?Button {
        for (self.items[0..self.len], 0..) |e, i| {
            if (!std.mem.eql(u8, e.name, name)) continue;
            std.mem.copyForwards(Event, self.items[i .. self.len - 1], self.items[i + 1 .. self.len]);
            self.len -= 1;
            return e.button;
        }
        return null;
    }

    pub fn isEmpty(self: *const Events) bool {
        return self.len == 0;
    }
};
