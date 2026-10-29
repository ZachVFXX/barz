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

The whole bar is described in `src/main.zig`. Every second, `main` asks each module for its data and decides how to display it:


| Call | What it does |
|------|--------------|
| `bar.begin()` | Start a new frame |
| `bar.item(fmt, args)` | Append an item and add separator |
| `bar.end()` | Print the line, sleep, advance `bar.tick` |


| Module | Data |
|--------|------|
| `battery` | `percent`, `status` |
| `ram` | `total`, `available`, `used` |
| `cpu` | `percent` |
| `clock` | `year`, `month`, `day`, `hour`, `minute`, `second` |
| `brightness` | `percent` |
| `speaker`, `micro` | `present`, `percent`, `muted`, `in_use` |


A module is a struct with:

```zig
pub const interval = 1;                                // seconds between read
pub const Data = struct { ... };                       // what the module returns
pub fn init(io: std.Io, gpa: std.mem.Allocator) !Self
pub fn deinit(self: *Self, io: std.Io) void
fn read(self: *Self, io: std.Io) !Data                 // does the actual reading
pub fn poll(self: *Self, io: std.Io, tick: u64) ?Data  // reads when due, returns cached data
```

```zig
const units = @import("units.zig");
units.from(16_000_000, .kib).to(.gib);
units.from(16, .).to(.gb);
```

## License
see `LICENSE`
