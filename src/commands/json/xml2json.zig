const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");
const xml = @import("../../formats/xml.zig");

/// Entry point for the xml2json command.
pub fn execute(ctx: context.Context, _: ?[]const u8) anyerror!void {
    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("xml2json: no input provided\n", .{});
        try writer.print("Usage: zuxi xml2json '<xml>'\n", .{});
        try writer.print("       cat file.xml | zuxi xml2json\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    // Parse XML input.
    var result = xml.parse(ctx.allocator, input.data) catch {
        const writer = ctx.stderrWriter();
        try writer.print("xml2json: invalid XML input\n", .{});
        return error.FormatError;
    };
    defer result.deinit();

    // Convert XML -> JSON value.
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const json_val = xml.toJsonValue(arena.allocator(), result.nodes) catch {
        const writer = ctx.stderrWriter();
        try writer.print("xml2json: conversion failed\n", .{});
        return error.FormatError;
    };

    // Serialize to pretty JSON.
    const json_str = std.json.Stringify.valueAlloc(ctx.allocator, json_val, .{
        .whitespace = .indent_4,
    }) catch {
        const writer = ctx.stderrWriter();
        try writer.print("xml2json: JSON serialization failed\n", .{});
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
    .name = "xml2json",
    .description = "Convert XML to JSON",
    .category = .json,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_xml2json_out.tmp";

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

test "xml2json simple element" {
    const output = try execWithInput("<name>zuxi</name>");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"zuxi\"") != null);
}

test "xml2json nested elements" {
    const output = try execWithInput("<root><child>value</child></root>");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"root\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"child\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"value\"") != null);
}

test "xml2json with attributes" {
    const output = try execWithInput("<item id=\"1\">test</item>");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"@id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"#text\"") != null);
}

test "xml2json self-closing" {
    const output = try execWithInput("<br />");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"br\"") != null);
}

test "xml2json command struct" {
    try std.testing.expectEqualStrings("xml2json", command.name);
    try std.testing.expectEqual(registry.Category.json, command.category);
}
