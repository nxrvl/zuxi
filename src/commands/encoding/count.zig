const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// Entry point for the count command.
/// Counts characters, words, and lines from input text.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    const mode: enum { all, chars, words, lines } = if (subcommand) |sub| blk: {
        if (std.mem.eql(u8, sub, "chars")) break :blk .chars;
        if (std.mem.eql(u8, sub, "words")) break :blk .words;
        if (std.mem.eql(u8, sub, "lines")) break :blk .lines;
        const writer = ctx.stderrWriter();
        try writer.print("count: unknown subcommand '{s}'\n", .{sub});
        try writer.print("Available subcommands: chars, words, lines\n", .{});
        return error.InvalidArgument;
    } else .all;

    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("count: no input provided\n", .{});
        try writer.print("Usage: zuxi count [chars|words|lines] <text>\n", .{});
        try writer.print("       echo 'text' | zuxi count\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    const data = input.data;
    var buf: [256]u8 = undefined;

    switch (mode) {
        .chars => {
            const result = std.fmt.bufPrint(&buf, "{d}\n", .{countChars(data)}) catch return error.BufferTooSmall;
            try io.writeOutput(ctx, result);
        },
        .words => {
            const result = std.fmt.bufPrint(&buf, "{d}\n", .{countWords(data)}) catch return error.BufferTooSmall;
            try io.writeOutput(ctx, result);
        },
        .lines => {
            const result = std.fmt.bufPrint(&buf, "{d}\n", .{countLines(data)}) catch return error.BufferTooSmall;
            try io.writeOutput(ctx, result);
        },
        .all => {
            const chars = countChars(data);
            const words = countWords(data);
            const line_count = countLines(data);
            const result = std.fmt.bufPrint(&buf, "Characters: {d}\nWords: {d}\nLines: {d}\n", .{ chars, words, line_count }) catch return error.BufferTooSmall;
            try io.writeOutput(ctx, result);
        },
    }
}

/// Count Unicode characters (codepoints) in a UTF-8 string.
fn countChars(data: []const u8) usize {
    var count: usize = 0;
    var view = std.unicode.Utf8View.initUnchecked(data);
    var it = view.iterator();
    while (it.nextCodepoint() != null) {
        count += 1;
    }
    return count;
}

/// Count words separated by whitespace.
fn countWords(data: []const u8) usize {
    var count: usize = 0;
    var in_word = false;
    for (data) |c| {
        if (std.ascii.isWhitespace(c)) {
            in_word = false;
        } else {
            if (!in_word) count += 1;
            in_word = true;
        }
    }
    return count;
}

/// Count lines. Empty input returns 0. Input with no newline returns 1.
fn countLines(data: []const u8) usize {
    if (data.len == 0) return 0;
    var count: usize = 0;
    for (data) |c| {
        if (c == '\n') count += 1;
    }
    // If last character is not a newline, count the final unterminated line.
    if (data[data.len - 1] != '\n') count += 1;
    return count;
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "count",
    .description = "Count characters, words, and lines in text",
    .category = .encoding,
    .subcommands = &.{ "chars", "words", "lines" },
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_count_out.tmp";

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

test "count all stats" {
    const output = try execWithInput("hello world", null);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("Characters: 11\nWords: 2\nLines: 1\n", output);
}

test "count chars only" {
    const output = try execWithInput("hello", "chars");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("5", trimmed);
}

test "count words only" {
    const output = try execWithInput("one two three", "words");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("3", trimmed);
}

test "count lines only" {
    const output = try execWithInput("line1\nline2\nline3\n", "lines");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("3", trimmed);
}

test "count empty input" {
    const output = try execWithInput("", null);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("Characters: 0\nWords: 0\nLines: 0\n", output);
}

test "count unicode chars" {
    // "Привет" is 6 characters but more bytes in UTF-8
    const output = try execWithInput("Привет", "chars");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("6", trimmed);
}

test "count multiple spaces between words" {
    const output = try execWithInput("one   two   three", "words");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("3", trimmed);
}

test "count lines without trailing newline" {
    const output = try execWithInput("line1\nline2", "lines");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("2", trimmed);
}

test "count single line no newline" {
    const output = try execWithInput("hello", "lines");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("1", trimmed);
}

test "count unknown subcommand" {
    const result = execWithInput("test", "paragraphs");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "count command struct fields" {
    try std.testing.expectEqualStrings("count", command.name);
    try std.testing.expectEqual(registry.Category.encoding, command.category);
    try std.testing.expectEqual(@as(usize, 3), command.subcommands.len);
}
