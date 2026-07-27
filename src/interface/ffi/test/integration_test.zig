// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// Cadastra FFI integration tests.
//
// These exercise the exported C ABI in src/main.zig (cadastra_init,
// cadastra_process, ...) the way a foreign caller linking against the
// compiled library would, as opposed to main.zig's own unit tests which
// run in-module.

const std = @import("std");
const main = @import("main");

test "lifecycle: create and destroy handle" {
    const handle = main.cadastra_init() orelse return error.InitFailed;
    defer main.cadastra_free(handle);

    try std.testing.expect(main.cadastra_is_initialized(handle) == 1);
}

test "operations: process with valid handle" {
    const handle = main.cadastra_init() orelse return error.InitFailed;
    defer main.cadastra_free(handle);

    const result = main.cadastra_process(handle, 42);
    try std.testing.expectEqual(main.Result.ok, result);
}

test "operations: process with null handle reports null_pointer" {
    const result = main.cadastra_process(null, 0);
    try std.testing.expectEqual(main.Result.null_pointer, result);

    const err = main.cadastra_last_error();
    try std.testing.expect(err != null);
}

test "strings: get string result from handle" {
    const handle = main.cadastra_init() orelse return error.InitFailed;
    defer main.cadastra_free(handle);

    const str = main.cadastra_get_string(handle);
    defer if (str) |s| main.cadastra_free_string(s);

    try std.testing.expect(str != null);
}

test "version: returns non-empty version string" {
    const ver = main.cadastra_version();
    const ver_str = std.mem.span(ver);
    try std.testing.expect(ver_str.len > 0);
}

test "build info: returns non-empty build info string" {
    const info = main.cadastra_build_info();
    const info_str = std.mem.span(info);
    try std.testing.expect(info_str.len > 0);
}
