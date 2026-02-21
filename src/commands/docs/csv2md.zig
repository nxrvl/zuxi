const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");
const csv = @import("csv.zig");

/// Convert CSV to a Markdown table.
/// First row is used as headers.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    if (subcommand) |sub| {
        const writer = ctx.stderrWriter();
        try writer.print("csv2md: unknown subcommand '{s}'\n", .{sub});
        return error.InvalidArgument;
    }

    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("csv2md: no input provided\n", .{});
        try writer.print("Usage: zuxi csv2md <csv-data>\n", .{});
        try writer.print("       echo 'a,b\\n1,2' | zuxi csv2md\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    const result = try tableToMarkdown(ctx.allocator, input.data, ',');
    defer ctx.allocator.free(result);

    try io.writeOutput(ctx, result);
}

/// Convert parsed CSV/TSV data to Markdown table format.
pub fn tableToMarkdown(allocator: std.mem.Allocator, data: []const u8, delimiter: u8) ![]u8 {
    const table = csv.parse(allocator, data, delimiter) catch {
        return error.InvalidInput;
    };
    defer table.deinit();

    if (table.rows.len == 0) {
        return try allocator.dupe(u8, "");
    }

    // Compute max column count
    var max_cols: usize = 0;
    for (table.rows) |row| {
        if (row.len > max_cols) max_cols = row.len;
    }

    // Compute column widths (minimum 3 for separator ---)
    const col_widths = try allocator.alloc(usize, max_cols);
    defer allocator.free(col_widths);
    for (col_widths) |*w| w.* = 3;

    for (table.rows) |row| {
        for (row, 0..) |field, ci| {
            if (ci < max_cols and field.len > col_widths[ci]) {
                col_widths[ci] = field.len;
            }
        }
    }

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    // Header row
    const headers = table.rows[0];
    try out.append(allocator, '|');
    for (0..max_cols) |ci| {
        try out.append(allocator, ' ');
        const field = if (ci < headers.len) headers[ci] else "";
        try out.appendSlice(allocator, field);
        // Pad to column width
        const padding = col_widths[ci] - field.len;
        for (0..padding) |_| try out.append(allocator, ' ');
        try out.appendSlice(allocator, " |");
    }
    try out.append(allocator, '\n');

    // Separator row
    try out.append(allocator, '|');
    for (0..max_cols) |ci| {
        try out.append(allocator, ' ');
        for (0..col_widths[ci]) |_| try out.append(allocator, '-');
        try out.appendSlice(allocator, " |");
    }
    try out.append(allocator, '\n');

    // Data rows
    for (table.rows[1..]) |row| {
        try out.append(allocator, '|');
        for (0..max_cols) |ci| {
            try out.append(allocator, ' ');
            const field = if (ci < row.len) row[ci] else "";
            try out.appendSlice(allocator, field);
            const padding = col_widths[ci] - field.len;
            for (0..padding) |_| try out.append(allocator, ' ');
            try out.appendSlice(allocator, " |");
        }
        try out.append(allocator, '\n');
    }

    return try out.toOwnedSlice(allocator);
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "csv2md",
    .description = "Convert CSV to Markdown table",
    .category = .docs,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_csv2md_out.tmp";

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

test "csv2md simple table" {
    const output = try execWithInput("name,age\nAlice,30\nBob,25\n", null);
    defer std.testing.allocator.free(output);

    const expected =
        "| name  | age |\n" ++
        "| ----- | --- |\n" ++
        "| Alice | 30  |\n" ++
        "| Bob   | 25  |\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "csv2md single column" {
    const output = try execWithInput("item\nfoo\nbar\n", null);
    defer std.testing.allocator.free(output);

    const expected =
        "| item |\n" ++
        "| ---- |\n" ++
        "| foo  |\n" ++
        "| bar  |\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "csv2md headers only" {
    const output = try execWithInput("a,b,c\n", null);
    defer std.testing.allocator.free(output);

    const expected =
        "| a   | b   | c   |\n" ++
        "| --- | --- | --- |\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "csv2md unknown subcommand" {
    const result = execWithInput("a,b\n1,2", "foo");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "csv2md command struct" {
    try std.testing.expectEqualStrings("csv2md", command.name);
    try std.testing.expectEqual(registry.Category.docs, command.category);
}
