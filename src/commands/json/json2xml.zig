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

    // Serialize to XML text.
    const parse_result = xml.ParseResult{
        .nodes = nodes,
        .declaration = null,
        .arena = arena,
    };
    // We need to serialize without deinit-ing the arena, so use a separate allocator.
    var ser_arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer ser_arena.deinit();

    var output_buf = std.ArrayList(u8){};
    const aa = ser_arena.allocator();

    // Write XML declaration.
    try output_buf.appendSlice(aa, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");

    // Write nodes.
    for (parse_result.nodes) |node| {
        try serializeNode(aa, &output_buf, node, 0);
    }

    try io.writeOutput(ctx, output_buf.items);
}

fn serializeNode(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    node: xml.Node,
    indent: usize,
) !void {
    switch (node) {
        .element => |elem| {
            for (0..indent) |_| try output.append(allocator, ' ');
            try output.append(allocator, '<');
            try output.appendSlice(allocator, elem.tag);

            for (elem.attributes) |attr| {
                try output.append(allocator, ' ');
                try output.appendSlice(allocator, attr.name);
                try output.appendSlice(allocator, "=\"");
                try output.appendSlice(allocator, attr.value);
                try output.append(allocator, '"');
            }

            if (elem.self_closing) {
                try output.appendSlice(allocator, " />\n");
                return;
            }

            try output.append(allocator, '>');

            if (elem.children.len == 1 and elem.children[0] == .text) {
                try output.appendSlice(allocator, elem.children[0].text);
                try output.appendSlice(allocator, "</");
                try output.appendSlice(allocator, elem.tag);
                try output.appendSlice(allocator, ">\n");
                return;
            }

            if (elem.children.len > 0) {
                try output.append(allocator, '\n');
                for (elem.children) |child| {
                    try serializeNode(allocator, output, child, indent + 2);
                }
                for (0..indent) |_| try output.append(allocator, ' ');
            }

            try output.appendSlice(allocator, "</");
            try output.appendSlice(allocator, elem.tag);
            try output.appendSlice(allocator, ">\n");
        },
        .text => |text| {
            for (0..indent) |_| try output.append(allocator, ' ');
            try output.appendSlice(allocator, text);
            try output.append(allocator, '\n');
        },
        .comment => |comment| {
            for (0..indent) |_| try output.append(allocator, ' ');
            try output.appendSlice(allocator, "<!-- ");
            try output.appendSlice(allocator, comment);
            try output.appendSlice(allocator, " -->\n");
        },
        .cdata => |cdata| {
            for (0..indent) |_| try output.append(allocator, ' ');
            try output.appendSlice(allocator, "<![CDATA[");
            try output.appendSlice(allocator, cdata);
            try output.appendSlice(allocator, "]]>\n");
        },
    }
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
