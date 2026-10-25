# barz

A tiny, fast status bar program for [swaybar](https://github.com/swaywm/sway) (and anything that reads status lines from stdout), written in Zig. A replacement for `i3status`.

## Build

Requires a Zig 0.17.0 toolchain
and a Nerd Font for the icons.

```sh
zig build --release=safe                 # build for release 
zig build --release=safe run              # test it in a terminal
zig build --release=safe --prefix ~/.config/sway/       # install to ~/.config/sway/bin/barz
```

## Use with sway

```
bar {
    position top
    status_command ~/.config/sway/bin/barz
    font pango:Iosevka Nerd Font 14
}
```

Then run `swaymsg reload` or `cmd+shift+c` on sway.

## Example

The whole bar is described in `main.zig`. Every second, `main` asks each module for its data and decides how to display it:

```zig
const std = @import("std");
const Bar = @import("bar.zig");
const Clock = @import("modules/clock.zig");
const Battery = @import("modules/battery.zig");
const Cpu = @import("modules/cpu.zig");
const Ram = @import("modules/ram.zig");
const units = @import("units.zig");

// See https://www.nerdfonts.com/cheat-sheet
const battery_icons = [_][]const u8{
    "\u{f008e}", "\u{f007a}", "\u{f007b}", "\u{f007c}", "\u{f007d}", "\u{f007e}",
    "\u{f007f}", "\u{f0080}", "\u{f0081}", "\u{f0082}", "\u{f0079}",
};
const battery_charging_icons = [_][]const u8{
    "\u{f089f}", "\u{f089c}", "\u{f0086}", "\u{f0087}", "\u{f0088}", "\u{f089d}",
    "\u{f0089}", "\u{f089e}", "\u{f008a}", "\u{f008b}", "\u{f0085}",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var bat = try Battery.init(io, init.gpa);
    defer bat.deinit(io);
    var ram = try Ram.init(io, init.gpa);
    defer ram.deinit(io);
    var cpu = try Cpu.init(io, init.gpa);
    defer cpu.deinit(io);
    var clock = try Clock.init(io, init.gpa);
    defer clock.deinit(io);

    var bar = Bar.init(io);

    while (true) {
        bar.begin();

        if (bat.poll(io, bar.tick)) |b| {
            const idx = @min(b.percent / 10, battery_icons.len - 1);
            const icon = if (b.status == .charging) battery_charging_icons[idx] else battery_icons[idx];
            bar.item("{d}% {s}", .{ b.percent, icon });
        }

        if (ram.poll(io, bar.tick)) |r| {
            const used = units.from(.kib, r.total_kb -| r.available_kb).to(.gib);
            bar.item("RAM {d:.1} GiB", .{used});
        }

        if (cpu.poll(io, bar.tick)) |c| bar.item("CPU {d:.0}%", .{c.percent});

        if (clock.poll(io, bar.tick)) |t| {
            bar.item("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
                t.year, t.month, t.day, t.hour, t.minute, t.second,
            });
        }

        try bar.end();
    }
}
```

The order of the `if` blocks is the order on the bar. Use normal Zig control flow to hide items, change icons, or pick units.

## Bar API

| Call | What it does |
|------|--------------|
| `bar.begin()` | Start a new frame |
| `bar.item(fmt, args)` | Append an item and add separator |
| `bar.end()` | Print the line, sleep, advance `bar.tick` |

## Modules

| Module | Data |
|--------|------|
| `battery` | `percent`, `status` |
| `ram` | `total`, `available`, `used` |
| `cpu` | `percent` |
| `clock` | `year`, `month`, `day`, `hour`, `minute`, `second` (local time from `/etc/localtime`) |
| `brightness` | `percent` |
| `volume`, `micro` | `percent`, `muted` (via `wpctl`) |

## Writing a module

A module is a struct with:

```zig
pub const interval = 1;                       // seconds between reads
pub const Data = struct { ... };              // what the module returns

pub fn init(io: std.Io, gpa: std.mem.Allocator) !Self
pub fn deinit(self: *Self, io: std.Io) void
fn read(self: *Self, io: std.Io) !Data        // does the actual reading
pub fn poll(self: *Self, io: std.Io, tick: u64) ?Data  // reads when due, returns cached data
```

`units.zig` helper for making more usefull module, see in `modules/` for exemple.

```zig
units.from(16_000_000, .kib).to(.gib);
units.from(16, .).to(.gb);
```

## License
see `LICENSE`
