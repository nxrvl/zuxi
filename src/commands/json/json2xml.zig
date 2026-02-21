const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");
const xml = @import("../../formats/xml.zig");

/// Entry point for the json2xml command.
pub fn execute(ctx: context.Context, _: ?[]const u8) anyerror!void {
    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("json2xml: no input provided\n", .{});
        try writer.print("Usage: zuxi json2xml '<json>'\n", .{});
        try writer.print("       echo '{{\"root\":{{\"key\":\"value\"}}}}' | zuxi json2xml\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    // Parse JSON input.
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, input.data, .{}) catch {
        const writer = ctx.stderrWriter();
        try writer.print("json2xml: invalid JSON input\n", .{});
        return error.FormatError;
    };
    defer parsed.deinit();

    // Convert JSON -> XML nodes.
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const nodes = xml.fromJsonValue(arena.allocator(), parsed.value) catch {
        const writer = ctx.stderrWriter();
        try writer.print("json2xml: conversion failed\n", .{});
        return error.FormatError;
    };

    // Serialize to XML text using the xml module's serializer (handles escaping).
    const parse_result = xml.ParseResult{
        .nodes = nodes,
        .declaration = null,
        .arena = arena,
    };
    const output = xml.serialize(ctx.allocator, parse_result) catch {
        const writer = ctx.stderrWriter();
        try writer.print("json2xml: serialization failed\n", .{});
        return error.FormatError;
    };
    defer ctx.allocator.free(output);

    // Prepend XML declaration.
    const decl = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
    const full_output = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ decl, output });
    defer ctx.allocator.free(full_output);

    try io.writeOutput(ctx, full_output);
}

pub const command = registry.Command{
    .name = "json2xml",
    .description = "Convert JSON to XML",
    .category = .json,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_json2xml_out.tmp";

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

test "json2xml simple object" {
    const output = try execWithInput("{\"name\":\"zuxi\"}");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "<?xml") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<name>zuxi</name>") != null);
}

test "json2xml nested object" {
    const output = try execWithInput("{\"root\":{\"child\":\"value\"}}");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "<root>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<child>value</child>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "</root>") != null);
}

test "json2xml with attributes" {
    const output = try execWithInput("{\"item\":{\"@id\":\"1\",\"#text\":\"test\"}}");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "id=\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "test") != null);
}

test "json2xml invalid input" {
    const result = execWithInput("not json");
    try std.testing.expectError(error.FormatError, result);
}

test "json2xml command struct" {
    try std.testing.expectEqualStrings("json2xml", command.name);
    try std.testing.expectEqual(registry.Category.json, command.category);
}
