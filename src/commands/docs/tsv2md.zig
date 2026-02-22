const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");
const csv2md = @import("csv2md.zig");

/// Convert TSV (tab-separated values) to a Markdown table.
/// First row is used as headers.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    if (subcommand) |sub| {
        const writer = ctx.stderrWriter();
        try writer.print("tsv2md: unknown subcommand '{s}'\n", .{sub});
        return error.InvalidArgument;
    }

    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("tsv2md: no input provided\n", .{});
        try writer.print("Usage: zuxi tsv2md <tsv-data>\n", .{});
        try writer.print("       echo 'a\\tb\\n1\\t2' | zuxi tsv2md\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    // Reuse csv2md's tableToMarkdown with tab delimiter
    const result = try csv2md.tableToMarkdown(ctx.allocator, input.data, '\t');
    defer ctx.allocator.free(result);

    try io.writeOutput(ctx, result);
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "tsv2md",
    .description = "Convert TSV to Markdown table",
    .category = .docs,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_tsv2md_out.tmp";

    const out_file = try std.fs.cwd().createFile(tmp_out, .{});

    const args = [_][]const u8{input};
    var ctx = context.Context.initDefault(allocator);
    ctx.args = &args;
    ctx.stdout = out_file;

    execute(ctx, subcommand) catch |err| {
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

test "tsv2md simple table" {
    const output = try execWithInput("name\tage\nAlice\t30\nBob\t25\n", null);
    defer std.testing.allocator.free(output);

    const expected =
        "| name  | age |\n" ++
        "| ----- | --- |\n" ++
        "| Alice | 30  |\n" ++
        "| Bob   | 25  |\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "tsv2md single column" {
    const output = try execWithInput("item\nfoo\nbar\n", null);
    defer std.testing.allocator.free(output);

    const expected =
        "| item |\n" ++
        "| ---- |\n" ++
        "| foo  |\n" ++
        "| bar  |\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "tsv2md with longer values" {
    const output = try execWithInput("id\tdescription\n1\tA longer text\n", null);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "| id") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "| description") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "| A longer text") != null);
}

test "tsv2md unknown subcommand" {
    const result = execWithInput("a\tb\n1\t2", "foo");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "tsv2md command struct" {
    try std.testing.expectEqualStrings("tsv2md", command.name);
    try std.testing.expectEqual(registry.Category.docs, command.category);
}
