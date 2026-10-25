const std = @import("std");
const Bar = @import("bar.zig");
const Clock = @import("modules/clock.zig");
const Battery = @import("modules/battery.zig");
const Cpu = @import("modules/cpu.zig");
const Ram = @import("modules/ram.zig");
const Brightness = @import("modules/brightness.zig");
const Volume = @import("modules/volume.zig");
const Micro = @import("modules/micro.zig");

const builtin = @import("builtin");
const units = @import("units.zig");

const battery_icons = [_][]const u8{
    "\u{f008e}", "\u{f007a}", "\u{f007b}", "\u{f007c}", "\u{f007d}", "\u{f007e}",
    "\u{f007f}", "\u{f0080}", "\u{f0081}", "\u{f0082}", "\u{f0079}",
};
const battery_charging_icons = [_][]const u8{
    "\u{f089f}", "\u{f089c}", "\u{f0086}", "\u{f0087}", "\u{f0088}", "\u{f089d}",
    "\u{f0089}", "\u{f089e}", "\u{f008a}", "\u{f008b}", "\u{f0085}",
};

const cpu32bit: []const u8 = "\u{f0edf}";
const cpu64bit: []const u8 = "\u{f0ee0}";

const cpu_icon: []const u8 = if (builtin.target.ptrBitWidth() == 64) cpu64bit else cpu32bit;

const icon_brightness = "\u{f00e0}";
const icon_vol = "\u{f057e}";
const icon_vol_muted = "\u{f0581}";
const icon_mic = "\u{f036c}";
const icon_mic_muted = "\u{f036d}";

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var battery = try Battery.init(io, init.gpa);
    defer battery.deinit(io);

    var ram = try Ram.init(io, init.gpa);
    defer ram.deinit(io);

    var cpu = try Cpu.init(io, init.gpa);
    defer cpu.deinit(io);

    var clock = try Clock.init(io, init.gpa);
    defer clock.deinit(io);

    var brightness = try Brightness.init(io, init.gpa, "amdgpu_bl0");
    defer brightness.deinit(io);

    var volume = try Volume.init(io, init.gpa);
    defer volume.deinit(io);

    var micro = try Micro.init(io, init.gpa);
    defer micro.deinit(io);

    var bar = Bar.init(io);

    while (true) {
        bar.begin();
        defer bar.end();

        if (battery.poll(io, bar.tick)) |b| {
            const idx = @min(b.percent / 10, battery_icons.len - 1);
            const icon = if (b.status == .charging) battery_charging_icons[idx] else battery_icons[idx];
            bar.item("{d}% {s}", .{ b.percent, icon });
        }

        if (volume.poll(io, bar.tick)) |v| {
            bar.item("{s} {d}%", .{ if (v.muted) icon_vol_muted else icon_vol, v.percent });
        }

        if (micro.poll(io, bar.tick)) |m| {
            bar.item("{s}", .{if (m.muted) icon_mic_muted else icon_mic});
        }

        if (ram.poll(io, bar.tick)) |r| {
            bar.item("RAM {d:.1} Gib", .{r.used.to(.gib)});
        }

        if (cpu.poll(io, bar.tick)) |c| {
            bar.item("CPU {d:.0}%", .{c.percent});
        }

        if (brightness.poll(io, bar.tick)) |b| {
            bar.item("Brightness {d:.0}%", .{b.percent});
        }

        if (clock.poll(io, bar.tick)) |t| {
            bar.item("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ t.year, t.month, t.day, t.hour, t.minute, t.second });
        }
    }
}
