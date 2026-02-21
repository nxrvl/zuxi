const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");
const yaml = @import("../../formats/yaml.zig");

/// Entry point for the yaml2json command.
pub fn execute(ctx: context.Context, _: ?[]const u8) anyerror!void {
    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("yaml2json: no input provided\n", .{});
        try writer.print("Usage: zuxi yaml2json '<yaml>'\n", .{});
        try writer.print("       echo 'key: value' | zuxi yaml2json\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    // Parse YAML input.
    var result = yaml.parse(ctx.allocator, input.data) catch {
        const writer = ctx.stderrWriter();
        try writer.print("yaml2json: invalid YAML input\n", .{});
        return error.FormatError;
    };
    defer result.deinit();

    // Convert YAML -> JSON value.
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const json_val = yaml.toJsonValue(arena.allocator(), result.value) catch {
        const writer = ctx.stderrWriter();
        try writer.print("yaml2json: conversion failed\n", .{});
        return error.FormatError;
    };

    // Serialize to pretty JSON.
    const json_str = std.json.Stringify.valueAlloc(ctx.allocator, json_val, .{
        .whitespace = .indent_4,
    }) catch {
        const writer = ctx.stderrWriter();
        try writer.print("yaml2json: JSON serialization failed\n", .{});
        return error.FormatError;
    };
    defer ctx.allocator.free(json_str);

    // Append newline.
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
    .name = "yaml2json",
    .description = "Convert YAML to JSON",
    .category = .json,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_yaml2json_out.tmp";

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

test "yaml2json simple mapping" {
    const output = try execWithInput("name: zuxi\nversion: 1");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"zuxi\"") != null);
}

test "yaml2json sequence" {
    const output = try execWithInput("- apple\n- banana");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "[") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"apple\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"banana\"") != null);
}

test "yaml2json nested" {
    const output = try execWithInput("server:\n  host: localhost\n  port: 8080");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"server\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"host\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"localhost\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "8080") != null);
}

test "yaml2json boolean and null" {
    const output = try execWithInput("active: true\nempty: null");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "null") != null);
}

test "yaml2json command struct" {
    try std.testing.expectEqualStrings("yaml2json", command.name);
    try std.testing.expectEqual(registry.Category.json, command.category);
}
