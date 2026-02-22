const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");
const xml = @import("../../formats/xml.zig");

/// Entry point for the xmlfmt command.
pub fn execute(ctx: context.Context, _: ?[]const u8) anyerror!void {
    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("xmlfmt: no input provided\n", .{});
        try writer.print("Usage: zuxi xmlfmt <xml>\n", .{});
        try writer.print("       echo '<root />' | zuxi xmlfmt\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    // Parse the XML.
    var result = xml.parse(ctx.allocator, input.data) catch {
        const writer = ctx.stderrWriter();
        try writer.print("xmlfmt: invalid XML input\n", .{});
        return error.FormatError;
    };
    defer result.deinit();

    // Serialize back with consistent formatting.
    const output = xml.serialize(ctx.allocator, result) catch {
        const writer = ctx.stderrWriter();
        try writer.print("xmlfmt: failed to format XML\n", .{});
        return error.FormatError;
    };
    defer ctx.allocator.free(output);

    try io.writeOutput(ctx, output);
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "xmlfmt",
    .description = "Format XML with consistent indentation",
    .category = .json,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_xmlfmt_out.tmp";

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

test "xmlfmt simple element" {
    const output = try execWithInput("<root>hello</root>");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("<root>hello</root>\n", output);
}

test "xmlfmt nested elements" {
    const output = try execWithInput("<root><child>text</child></root>");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "<root>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  <child>text</child>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "</root>\n") != null);
}

test "xmlfmt self-closing" {
    const output = try execWithInput("<br />");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("<br />\n", output);
}

test "xmlfmt with attributes" {
    const output = try execWithInput("<div class=\"main\">content</div>");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "class=\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "content") != null);
}

test "xmlfmt with declaration" {
    const output = try execWithInput("<?xml version=\"1.0\"?><root />");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "<?xml") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<root />\n") != null);
}

test "xmlfmt complex document" {
    const input = "<html><head><title>Test</title></head><body><p>Hello</p><br /><p>World</p></body></html>";
    const output = try execWithInput(input);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "<html>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  <head>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "    <title>Test</title>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  <body>\n") != null);
}

test "xmlfmt command struct fields" {
    try std.testing.expectEqualStrings("xmlfmt", command.name);
    try std.testing.expectEqual(registry.Category.json, command.category);
}
