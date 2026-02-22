const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");
const toml = @import("../../formats/toml.zig");

/// Entry point for the json2toml command.
pub fn execute(ctx: context.Context, _: ?[]const u8) anyerror!void {
    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("json2toml: no input provided\n", .{});
        try writer.print("Usage: zuxi json2toml '<json>'\n", .{});
        try writer.print("       echo '{{\"key\":\"value\"}}' | zuxi json2toml\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    // Parse JSON input.
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, input.data, .{}) catch {
        const writer = ctx.stderrWriter();
        try writer.print("json2toml: invalid JSON input\n", .{});
        return error.FormatError;
    };
    defer parsed.deinit();

    // Convert JSON -> TOML value.
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const toml_val = toml.fromJsonValue(arena.allocator(), parsed.value) catch {
        const writer = ctx.stderrWriter();
        try writer.print("json2toml: conversion failed\n", .{});
        return error.FormatError;
    };

    // Serialize to TOML text.
    const output = toml.serialize(arena.allocator(), toml_val) catch {
        const writer = ctx.stderrWriter();
        try writer.print("json2toml: serialization failed\n", .{});
        return error.FormatError;
    };

    try io.writeOutput(ctx, output);
}

pub const command = registry.Command{
    .name = "json2toml",
    .description = "Convert JSON to TOML",
    .category = .json,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_json2toml_out.tmp";

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

test "json2toml simple object" {
    const output = try execWithInput("{\"name\":\"zuxi\",\"port\":8080}");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "name = \"zuxi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "port = 8080") != null);
}

test "json2toml boolean values" {
    const output = try execWithInput("{\"debug\":true,\"verbose\":false}");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "debug = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "verbose = false") != null);
}

test "json2toml nested object" {
    const output = try execWithInput("{\"server\":{\"host\":\"localhost\",\"port\":8080}}");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "[server]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "host = \"localhost\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "port = 8080") != null);
}

test "json2toml array" {
    const output = try execWithInput("{\"colors\":[\"red\",\"green\",\"blue\"]}");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "colors = [") != null);
}

test "json2toml invalid input" {
    const result = execWithInput("not json");
    try std.testing.expectError(error.FormatError, result);
}

test "json2toml command struct" {
    try std.testing.expectEqualStrings("json2toml", command.name);
    try std.testing.expectEqual(registry.Category.json, command.category);
}
