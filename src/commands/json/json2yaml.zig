const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");
const yaml = @import("../../formats/yaml.zig");

/// Entry point for the json2yaml command.
pub fn execute(ctx: context.Context, _: ?[]const u8) anyerror!void {
    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("json2yaml: no input provided\n", .{});
        try writer.print("Usage: zuxi json2yaml '<json>'\n", .{});
        try writer.print("       echo '{{\"key\":\"value\"}}' | zuxi json2yaml\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    // Parse JSON input.
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, input.data, .{}) catch {
        const writer = ctx.stderrWriter();
        try writer.print("json2yaml: invalid JSON input\n", .{});
        return error.FormatError;
    };
    defer parsed.deinit();

    // Convert JSON -> YAML value.
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const yaml_val = yaml.fromJsonValue(arena.allocator(), parsed.value) catch {
        const writer = ctx.stderrWriter();
        try writer.print("json2yaml: conversion failed\n", .{});
        return error.FormatError;
    };

    // Serialize to YAML text.
    const output = yaml.serialize(arena.allocator(), yaml_val) catch {
        const writer = ctx.stderrWriter();
        try writer.print("json2yaml: serialization failed\n", .{});
        return error.FormatError;
    };

    try io.writeOutput(ctx, output);
}

pub const command = registry.Command{
    .name = "json2yaml",
    .description = "Convert JSON to YAML",
    .category = .json,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_json2yaml_out.tmp";

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

test "json2yaml simple object" {
    const output = try execWithInput("{\"name\":\"zuxi\",\"version\":\"0.1\"}");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "name: zuxi") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "version:") != null);
}

test "json2yaml array" {
    const output = try execWithInput("[\"apple\",\"banana\",\"cherry\"]");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "- apple") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "- banana") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "- cherry") != null);
}

test "json2yaml nested object" {
    const output = try execWithInput("{\"server\":{\"host\":\"localhost\",\"port\":8080}}");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "server:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "host: localhost") != null);
}

test "json2yaml with types" {
    const output = try execWithInput("{\"active\":true,\"count\":42,\"empty\":null}");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "active:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "count:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "empty:") != null);
}

test "json2yaml invalid input" {
    const result = execWithInput("not json");
    try std.testing.expectError(error.FormatError, result);
}

test "json2yaml command struct" {
    try std.testing.expectEqualStrings("json2yaml", command.name);
    try std.testing.expectEqual(registry.Category.json, command.category);
}
