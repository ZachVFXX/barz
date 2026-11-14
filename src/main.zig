const std = @import("std");
const Bar = @import("bar.zig");
const Clock = @import("modules/clock.zig");
const Battery = @import("modules/battery.zig");
const Cpu = @import("modules/cpu.zig");
const Ram = @import("modules/ram.zig");
const Brightness = @import("modules/brightness.zig");
const Pipewire = @import("modules/pipewire.zig");

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
const in_use_dot = " \u{ea71}";
const not_use_dot = " \u{eabc}";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var cpu = try Cpu.init(io, gpa, .fromSeconds(1));
    defer cpu.deinit(io);

    var ram = try Ram.init(io, gpa, .fromSeconds(2));
    defer ram.deinit(io);

    var battery = try Battery.init(io, gpa, .fromSeconds(30));
    defer battery.deinit(io);

    var brightness = try Brightness.init(io, gpa, "amdgpu_bl0", .fromSeconds(1));
    defer brightness.deinit(io);

    var audio = try Pipewire.init(io, gpa, .fromMilliseconds(25));
    defer audio.deinit(io);

    var clock = try Clock.init(io, init.gpa, .fromSeconds(1));
    defer clock.deinit(io);

    var buffer: [512]u8 = undefined;
    var bar = Bar.init(io, &buffer);

    while (true) {
        bar.begin();
        defer bar.end();

        if (bar.get(&cpu)) |c| bar.item("CPU {d:.0}%", .{c.percent});

        if (bar.get(&ram)) |r| {
            const result = r.used.humanize(.iec);
            bar.item("RAM {d:.1} {s} ({d:.1}%)", .{ result.value, result.unit.name(), r.percent });
        }

        if (bar.get(&audio)) |d| {
            if (d.speaker.present) {
                const dot: []const u8 = if (d.speaker.in_use) in_use_dot else not_use_dot;
                bar.item("{s} {d}%{s}", .{ if (d.speaker.muted) icon_vol_muted else icon_vol, d.speaker.percent, dot });
            }
            if (d.micro.present) {
                const dot: []const u8 = if (d.micro.in_use) in_use_dot else not_use_dot;
                bar.item("{s} {d}%{s}", .{ if (d.micro.muted) icon_mic_muted else icon_mic, d.micro.percent, dot });
            }
        }
        if (bar.get(&brightness)) |b| bar.item("{d:.0}% {s}", .{ b.percent, icon_brightness });

        if (bar.get(&battery)) |b| {
            const idx = @min(b.percent / 10, battery_icons.len - 1);
            const icon = if (b.status == .charging) battery_charging_icons[idx] else battery_icons[idx];
            bar.item("{d}% {s}", .{ b.percent, icon });
        }
        if (bar.get(&clock)) |t| {
            bar.item("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ t.year, t.month, t.day, t.hour, t.minute, t.second });
        }
    }
}
