const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// Entry point for the jsonrepair command.
pub fn execute(ctx: context.Context, _: ?[]const u8) anyerror!void {
    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("jsonrepair: no input provided\n", .{});
        try writer.print("Usage: zuxi jsonrepair <broken-json>\n", .{});
        try writer.print("       echo '{{...}}' | zuxi jsonrepair\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    const repaired = repair(ctx.allocator, input.data) catch {
        const writer = ctx.stderrWriter();
        try writer.print("jsonrepair: unable to repair JSON\n", .{});
        return error.FormatError;
    };
    defer ctx.allocator.free(repaired);

    // Validate the repaired JSON.
    const valid = std.json.Scanner.validate(ctx.allocator, repaired) catch return error.OutOfMemory;
    if (!valid) {
        const writer = ctx.stderrWriter();
        try writer.print("jsonrepair: repaired output is not valid JSON\n", .{});
        return error.FormatError;
    }

    try io.writeOutput(ctx, repaired);
    const writer = ctx.stdoutWriter();
    try writer.writeByte('\n');
}

/// Attempt to repair broken JSON by applying common fixes:
/// 1. Remove JS-style comments (// and /* */)
/// 2. Replace single quotes with double quotes
/// 3. Quote unquoted keys
/// 4. Remove trailing commas before } and ]
pub fn repair(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Phase 1: Remove comments.
    const no_comments = try removeComments(allocator, input);
    defer allocator.free(no_comments);

    // Phase 2: Fix quotes (single -> double) and quote unquoted keys.
    const fixed_quotes = try fixQuotesAndKeys(allocator, no_comments);
    defer allocator.free(fixed_quotes);

    // Phase 3: Remove trailing commas.
    const result = try removeTrailingCommas(allocator, fixed_quotes);
    return result;
}

/// Remove JS-style single-line (//) and multi-line (/* */) comments.
fn removeComments(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '"') {
            // Skip over strings entirely (don't remove comment-like content inside strings).
            const str_end = findStringEndDouble(input, i);
            try result.appendSlice(allocator, input[i..str_end]);
            i = str_end;
        } else if (i + 1 < input.len and input[i] == '/' and input[i + 1] == '/') {
            // Single-line comment: skip to end of line.
            i += 2;
            while (i < input.len and input[i] != '\n') : (i += 1) {}
        } else if (i + 1 < input.len and input[i] == '/' and input[i + 1] == '*') {
            // Multi-line comment: skip to */.
            i += 2;
            var found_end = false;
            while (i + 1 < input.len) {
                if (input[i] == '*' and input[i + 1] == '/') {
                    i += 2;
                    found_end = true;
                    break;
                }
                i += 1;
            }
            if (!found_end) {
                // Unterminated comment - skip rest.
                i = input.len;
            }
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }
    return try result.toOwnedSlice(allocator);
}

/// Fix single quotes to double quotes and add quotes around unquoted keys.
fn fixQuotesAndKeys(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '"') {
            // Already double-quoted string, copy it through.
            const str_end = findStringEndDouble(input, i);
            try result.appendSlice(allocator, input[i..str_end]);
            i = str_end;
        } else if (input[i] == '\'') {
            // Single-quoted string -> convert to double quotes.
            try result.append(allocator, '"');
            i += 1;
            while (i < input.len and input[i] != '\'') {
                if (input[i] == '\\' and i + 1 < input.len) {
                    if (input[i + 1] == '\'') {
                        // \' -> just write the quote (no backslash needed inside double quotes).
                        try result.append(allocator, '\'');
                        i += 2;
                    } else {
                        try result.append(allocator, input[i]);
                        try result.append(allocator, input[i + 1]);
                        i += 2;
                    }
                } else if (input[i] == '"') {
                    // Escape double quotes that appear inside single-quoted strings.
                    try result.appendSlice(allocator, "\\\"");
                    i += 1;
                } else {
                    try result.append(allocator, input[i]);
                    i += 1;
                }
            }
            try result.append(allocator, '"');
            if (i < input.len) i += 1; // Skip closing single quote.
        } else if (isUnquotedKeyStart(input, i)) {
            // Unquoted key: collect identifier chars and wrap in quotes.
            try result.append(allocator, '"');
            while (i < input.len and isIdentChar(input[i])) {
                try result.append(allocator, input[i]);
                i += 1;
            }
            try result.append(allocator, '"');
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }
    return try result.toOwnedSlice(allocator);
}

/// Check if position i is the start of an unquoted key.
/// An unquoted key is an identifier followed by optional whitespace then ':'.
fn isUnquotedKeyStart(input: []const u8, pos: usize) bool {
    if (pos >= input.len) return false;
    const c = input[pos];
    // Must start with letter or underscore.
    if (!std.ascii.isAlphabetic(c) and c != '_' and c != '$') return false;

    // Scan forward past identifier chars.
    var i = pos;
    while (i < input.len and isIdentChar(input[i])) : (i += 1) {}

    // Check this isn't a JSON keyword (true, false, null).
    const ident = input[pos..i];
    if (std.mem.eql(u8, ident, "true") or std.mem.eql(u8, ident, "false") or std.mem.eql(u8, ident, "null")) {
        return false;
    }

    // Skip whitespace.
    while (i < input.len and isWhitespace(input[i])) : (i += 1) {}

    // Must be followed by ':'.
    return i < input.len and input[i] == ':';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Remove trailing commas before } and ].
fn removeTrailingCommas(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '"') {
            // Copy strings verbatim.
            const str_end = findStringEndDouble(input, i);
            try result.appendSlice(allocator, input[i..str_end]);
            i = str_end;
        } else if (input[i] == ',') {
            // Check if this comma is trailing (only whitespace before } or ]).
            var j = i + 1;
            while (j < input.len and isWhitespace(input[j])) : (j += 1) {}
            if (j < input.len and (input[j] == '}' or input[j] == ']')) {
                // Trailing comma - skip it.
                i += 1;
            } else {
                try result.append(allocator, input[i]);
                i += 1;
            }
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }
    return try result.toOwnedSlice(allocator);
}

/// Find the end of a double-quoted string (handles escapes).
fn findStringEndDouble(input: []const u8, pos: usize) usize {
    var i = pos + 1;
    while (i < input.len) {
        if (input[i] == '\\') {
            i += 2;
            continue;
        }
        if (input[i] == '"') {
            return i + 1;
        }
        i += 1;
    }
    return input.len;
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "jsonrepair",
    .description = "Fix common broken JSON issues",
    .category = .json,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_jsonrepair_out.tmp";

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

test "jsonrepair trailing comma in object" {
    const output = try execWithInput("{\"a\": 1, \"b\": 2,}");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("{\"a\": 1, \"b\": 2}", trimmed);
}

test "jsonrepair trailing comma in array" {
    const output = try execWithInput("[1, 2, 3,]");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("[1, 2, 3]", trimmed);
}

test "jsonrepair single quotes to double quotes" {
    const output = try execWithInput("{'name': 'zuxi'}");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("{\"name\": \"zuxi\"}", trimmed);
}

test "jsonrepair unquoted keys" {
    const output = try execWithInput("{name: \"zuxi\", version: 1}");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("{\"name\": \"zuxi\", \"version\": 1}", trimmed);
}

test "jsonrepair single-line comments" {
    const input = "{\n  \"a\": 1, // this is a comment\n  \"b\": 2\n}";
    const output = try execWithInput(input);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    // Should not contain the comment.
    try std.testing.expect(std.mem.indexOf(u8, trimmed, "//") == null);
    try std.testing.expect(std.mem.indexOf(u8, trimmed, "comment") == null);
    // Should still be valid JSON with both keys.
    try std.testing.expect(std.mem.indexOf(u8, trimmed, "\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, trimmed, "\"b\"") != null);
}

test "jsonrepair multi-line comments" {
    const input = "{/* comment */\"a\": 1}";
    const output = try execWithInput(input);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("{\"a\": 1}", trimmed);
}

test "jsonrepair combined fixes" {
    // Single quotes + trailing comma + unquoted keys.
    const input = "{name: 'zuxi', version: 1,}";
    const output = try execWithInput(input);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("{\"name\": \"zuxi\", \"version\": 1}", trimmed);
}

test "jsonrepair valid JSON passes through" {
    const input = "{\"a\": 1, \"b\": [2, 3]}";
    const output = try execWithInput(input);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings(input, trimmed);
}

test "jsonrepair empty input gives error" {
    // Empty input is not valid JSON and can't be repaired.
    const result = execWithInput("");
    try std.testing.expectError(error.FormatError, result);
}

test "jsonrepair preserves strings with comment-like content" {
    const input = "{\"url\": \"http://example.com\"}";
    const output = try execWithInput(input);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings(input, trimmed);
}

test "jsonrepair does not quote true/false/null as keys" {
    const input = "{\"val\": true, \"other\": null}";
    const output = try execWithInput(input);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings(input, trimmed);
}

test "jsonrepair nested trailing commas" {
    const input = "{\"a\": [1, 2,], \"b\": {\"c\": 3,},}";
    const output = try execWithInput(input);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("{\"a\": [1, 2], \"b\": {\"c\": 3}}", trimmed);
}

test "jsonrepair command struct fields" {
    try std.testing.expectEqualStrings("jsonrepair", command.name);
    try std.testing.expectEqual(registry.Category.json, command.category);
}

test "repair function directly" {
    const allocator = std.testing.allocator;
    const result = try repair(allocator, "{key: 'val',}");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("{\"key\": \"val\"}", result);
}
