const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");
const toml = @import("../../formats/toml.zig");

/// Entry point for the toml2json command.
pub fn execute(ctx: context.Context, _: ?[]const u8) anyerror!void {
    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("toml2json: no input provided\n", .{});
        try writer.print("Usage: zuxi toml2json '<toml>'\n", .{});
        try writer.print("       cat config.toml | zuxi toml2json\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    // Parse TOML input.
    var result = toml.parse(ctx.allocator, input.data) catch {
        const writer = ctx.stderrWriter();
        try writer.print("toml2json: invalid TOML input\n", .{});
        return error.FormatError;
    };
    defer result.deinit();

    // Convert TOML -> JSON value.
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const json_val = toml.toJsonValue(arena.allocator(), result.value) catch {
        const writer = ctx.stderrWriter();
        try writer.print("toml2json: conversion failed\n", .{});
        return error.FormatError;
    };

    // Serialize to pretty JSON.
    const json_str = std.json.Stringify.valueAlloc(ctx.allocator, json_val, .{
        .whitespace = .indent_4,
    }) catch {
        const writer = ctx.stderrWriter();
        try writer.print("toml2json: JSON serialization failed\n", .{});
        return error.FormatError;
    };
    defer ctx.allocator.free(json_str);

    const output = try appendNewline(ctx.allocator, json_str);
    defer ctx.allocator.free(output);
    try io.writeOutput(ctx, output);
}

fn appendNewline(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result = try allocator.alloc(u8, s.len + 1);
    @memcpy(result[0..s.len], s);
    result[s.len] = '\n';
    return result;
}

pub const command = registry.Command{
    .name = "toml2json",
    .description = "Convert TOML to JSON",
    .category = .json,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_toml2json_out.tmp";

    const out_file = try std.fs.cwd().createFile(tmp_out, .{});

    const args = [_][]const u8{input};
    var ctx = context.Context.initDefault(allocator);
    ctx.args = &args;
    ctx.stdout = out_file;

    execute(ctx, null) catch |err| {
        out_file.close();
        std.fs.cwd().deleteFile(tmp_out) catch {};
        return err;
    };
    out_file.close();

    const file = try std.fs.cwd().openFile(tmp_out, .{});
    defer file.close();
    defer std.fs.cwd().deleteFile(tmp_out) catch {};
    return try file.readToEndAlloc(allocator, io.max_input_size);
}

test "toml2json simple key-values" {
    const output = try execWithInput("name = \"zuxi\"\nport = 8080\n");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"zuxi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "8080") != null);
}

test "toml2json with table" {
    const output = try execWithInput("[server]\nhost = \"localhost\"\nport = 8080\n");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"server\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"host\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"localhost\"") != null);
}

test "toml2json boolean" {
    const output = try execWithInput("debug = true\n");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "true") != null);
}

test "toml2json array" {
    const output = try execWithInput("ports = [80, 443, 8080]\n");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "80") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "443") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "8080") != null);
}

test "toml2json invalid input" {
    const result = execWithInput("= no key");
    try std.testing.expectError(error.FormatError, result);
}

test "toml2json command struct" {
    try std.testing.expectEqualStrings("toml2json", command.name);
    try std.testing.expectEqual(registry.Category.json, command.category);
}
