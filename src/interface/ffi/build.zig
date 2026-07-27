// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// Zig build for the Cadastra ABI/FFI seam (Zig 0.16+).
//
// `zig build test` runs both the unit tests embedded in src/main.zig and the
// integration tests in test/integration_test.zig, which exercise the
// exported C ABI (cadastra_init, cadastra_process, ...) the way a foreign
// caller would.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const main_tests = b.addTest(.{ .root_module = main_module });
    const run_main_tests = b.addRunArtifact(main_tests);

    const integration_module = b.createModule(.{
        .root_source_file = b.path("test/integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "main", .module = main_module },
        },
    });
    const integration_tests = b.addTest(.{ .root_module = integration_module });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}
