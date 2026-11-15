# barz

A tiny, fast status bar program for [swaybar](https://github.com/swaywm/sway) (and anything that reads status lines from stdout), written in Zig. A replacement for `i3status`.

## Build

Requires a Zig 0.17.0 toolchain
and a Nerd Font for the icons.

```sh
zig build --release=safe                            # build for release 
zig build --release=safe run                        # test it in a terminal
zig build --release=safe --prefix ~/.config/sway/   # install to ~/.config/sway/bin/barz
```

## Use with sway

```
bar {
    position top
    status_command ~/.config/sway/bin/barz
    font pango:Iosevka Nerd Font 14
}
```

Then run `swaymsg reload` or `mod+shift+c` on sway.

## Example

The whole bar is described in `src/main.zig`. `main` asks each module for its data and update it if needed and decides how to display it:


| Call | What it does |
|------|--------------|
| `bar.begin()` | Start a new frame |
| `bar.item(fmt, args)` | Append an item and add separator |
| `bar.get(&module)`  | get module data and update if needed |
| `bar.end()` | Print the line and wait for the next deadline |


| Module | Data |
|--------|------|
| `battery` | `percent`, `status` |
| `ram` | `total`, `available`, `used`, `percent` |
| `cpu` | `percent` |
| `clock` | `year`, `month`, `day`, `hour`, `minute`, `second` |
| `brightness` | `percent` |
| `speaker`, `micro` | `present`, `percent`, `muted`, `in_use` |


A module is a struct with:

```zig
interval = std.Io.Duration;                                // seconds between read
pub const Data = struct { ... };                           // what the module returns
pub fn init(io: std.Io, gpa: std.mem.Allocator, interval: std.Io.Duration) !Self
pub fn deinit(self: *Self, io: std.Io) void
pub fn read(self: *Self, io: std.Io) !Data                 // does the actual reading
```

```zig
const units = @import("units.zig");
units.from(16_000_000, .kib).to(.gib);
units.from(16, .).to(.gb);

// Exemple in main.zig
result = r.used.humanize(.iec);
bar.item("RAM {d:.1} {s} ({d:.1}%)", .{ result.value, result.unit.name(), r.percent });
```

## License
see `LICENSE`
