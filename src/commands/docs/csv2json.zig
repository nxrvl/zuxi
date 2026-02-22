const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");
const csv = @import("csv.zig");

/// Convert CSV to JSON array of objects.
/// First row is used as headers/keys.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    if (subcommand) |sub| {
        const writer = ctx.stderrWriter();
        try writer.print("csv2json: unknown subcommand '{s}'\n", .{sub});
        return error.InvalidArgument;
    }

    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("csv2json: no input provided\n", .{});
        try writer.print("Usage: zuxi csv2json <csv-data>\n", .{});
        try writer.print("       echo 'a,b\\n1,2' | zuxi csv2json\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    const table = csv.parse(ctx.allocator, input.data, ',') catch {
        const writer = ctx.stderrWriter();
        try writer.print("csv2json: failed to parse CSV\n", .{});
        return error.InvalidInput;
    };
    defer table.deinit();

    if (table.rows.len == 0) {
        try io.writeOutput(ctx, "[]\n");
        return;
    }

    const headers = table.rows[0];
    const data_rows = table.rows[1..];

    // Build JSON output
    var out = std.ArrayList(u8){};
    defer out.deinit(ctx.allocator);

    try out.appendSlice(ctx.allocator, "[\n");
    for (data_rows, 0..) |row, ri| {
        try out.appendSlice(ctx.allocator, "  {");
        const field_count = @min(row.len, headers.len);
        for (0..field_count) |fi| {
            if (fi > 0) try out.appendSlice(ctx.allocator, ",");
            try out.appendSlice(ctx.allocator, "\n    ");
            try writeJsonString(ctx.allocator, &out, headers[fi]);
            try out.appendSlice(ctx.allocator, ": ");
            try writeJsonString(ctx.allocator, &out, row[fi]);
        }
        try out.appendSlice(ctx.allocator, "\n  }");
        if (ri + 1 < data_rows.len) {
            try out.appendSlice(ctx.allocator, ",");
        }
        try out.appendSlice(ctx.allocator, "\n");
    }
    try out.appendSlice(ctx.allocator, "]\n");

    try io.writeOutput(ctx, out.items);
}

/// Write a JSON-escaped string with surrounding quotes.
fn writeJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try out.appendSlice(allocator, hex);
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "csv2json",
    .description = "Convert CSV to JSON array of objects",
    .category = .docs,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_csv2json_out.tmp";

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

test "csv2json simple" {
    const output = try execWithInput("name,age\nAlice,30\nBob,25\n", null);
    defer std.testing.allocator.free(output);

    // Verify it's valid JSON-like structure
    try std.testing.expect(std.mem.indexOf(u8, output, "\"name\": \"Alice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"age\": \"30\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"name\": \"Bob\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"age\": \"25\"") != null);
    try std.testing.expect(std.mem.startsWith(u8, output, "["));
}

test "csv2json with quoted fields" {
    const output = try execWithInput("name,desc\nAlice,\"Hello, World\"\n", null);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"desc\": \"Hello, World\"") != null);
}

test "csv2json empty data rows" {
    const output = try execWithInput("a,b\n", null);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("[\n]\n", output);
}

test "csv2json headers only no trailing newline" {
    const output = try execWithInput("a,b", null);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("[\n]\n", output);
}

test "csv2json unknown subcommand" {
    const result = execWithInput("a,b\n1,2", "foo");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "csv2json command struct" {
    try std.testing.expectEqualStrings("csv2json", command.name);
    try std.testing.expectEqual(registry.Category.docs, command.category);
}
