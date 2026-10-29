const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "barz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = true,
        }),
    });

    const pipewire = b.dependency("pipewire", .{
        .optimize = optimize,
        .target = target,
    });

    exe.root_module.addImport("pipewire", pipewire.module("pipewire"));

    b.installArtifact(exe);
    
    const run_step = b.step("run", "Run the bar in your terminal");
    const run_cmd = b.addRunArtifact(exe);

    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
}
