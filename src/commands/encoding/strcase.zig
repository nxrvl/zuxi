const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// Supported case conversions.
const CaseMode = enum {
    snake,
    camel,
    pascal,
    kebab,
    upper,
};

/// Entry point for the strcase command.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    const mode: CaseMode = if (subcommand) |sub| blk: {
        if (std.mem.eql(u8, sub, "snake")) break :blk .snake;
        if (std.mem.eql(u8, sub, "camel")) break :blk .camel;
        if (std.mem.eql(u8, sub, "pascal")) break :blk .pascal;
        if (std.mem.eql(u8, sub, "kebab")) break :blk .kebab;
        if (std.mem.eql(u8, sub, "upper")) break :blk .upper;
        const writer = ctx.stderrWriter();
        try writer.print("strcase: unknown subcommand '{s}'\n", .{sub});
        try writer.print("Available subcommands: snake, camel, pascal, kebab, upper\n", .{});
        return error.InvalidArgument;
    } else {
        const writer = ctx.stderrWriter();
        try writer.print("strcase: subcommand required\n", .{});
        try writer.print("Usage: zuxi strcase <snake|camel|pascal|kebab|upper> <string>\n", .{});
        return error.MissingArgument;
    };

    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("strcase: no input provided\n", .{});
        try writer.print("Usage: zuxi strcase {s} <string>\n", .{@tagName(mode)});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    const result = try convertCase(ctx.allocator, input.data, mode);
    defer ctx.allocator.free(result);
    try io.writeOutput(ctx, result);
}

/// Split input string into words by detecting boundaries at:
/// - underscores, hyphens, spaces
/// - transitions from lowercase to uppercase (camelCase boundaries)
/// Returns a list of lowercase word slices allocated from the provided allocator.
fn splitIntoWords(allocator: std.mem.Allocator, input: []const u8) ![][]u8 {
    var words = std.ArrayList([]u8){};
    defer words.deinit(allocator);
    errdefer for (words.items) |w| allocator.free(w);

    var word_start: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        // Check if this character is a separator.
        if (c == '_' or c == '-' or c == ' ' or c == '\t') {
            if (i > word_start) {
                const word = try toLowerAlloc(allocator, input[word_start..i]);
                try words.append(allocator, word);
            }
            i += 1;
            word_start = i;
            continue;
        }
        // Check for camelCase boundary: lowercase followed by uppercase.
        if (i > word_start and std.ascii.isUpper(c)) {
            // Check if previous char was lowercase (camelCase boundary).
            if (i > 0 and std.ascii.isLower(input[i - 1])) {
                const word = try toLowerAlloc(allocator, input[word_start..i]);
                try words.append(allocator, word);
                word_start = i;
                i += 1;
                continue;
            }
            // Check for ALLCAPS followed by a lowercase (e.g., "XMLParser" -> "XML", "Parser").
            if (i > 0 and std.ascii.isUpper(input[i - 1]) and i + 1 < input.len and std.ascii.isLower(input[i + 1])) {
                const word = try toLowerAlloc(allocator, input[word_start..i]);
                try words.append(allocator, word);
                word_start = i;
                i += 1;
                continue;
            }
        }
        i += 1;
    }
    // Capture the last word.
    if (word_start < input.len) {
        const word = try toLowerAlloc(allocator, input[word_start..]);
        try words.append(allocator, word);
    }

    return try words.toOwnedSlice(allocator);
}

/// Allocate a lowercase copy of a string.
fn toLowerAlloc(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, idx| {
        result[idx] = std.ascii.toLower(c);
    }
    return result;
}

/// Convert input to the target case and return as an allocated string with trailing newline.
fn convertCase(allocator: std.mem.Allocator, input: []const u8, mode: CaseMode) ![]u8 {
    if (mode == .upper) {
        const result = try allocator.alloc(u8, input.len + 1);
        for (input, 0..) |c, i| {
            result[i] = std.ascii.toUpper(c);
        }
        result[input.len] = '\n';
        return result;
    }

    const words = try splitIntoWords(allocator, input);
    defer {
        for (words) |w| allocator.free(w);
        allocator.free(words);
    }

    if (words.len == 0) {
        const result = try allocator.alloc(u8, 1);
        result[0] = '\n';
        return result;
    }

    return switch (mode) {
        .snake => try joinWith(allocator, words, '_'),
        .kebab => try joinWith(allocator, words, '-'),
        .camel => try buildCamelCase(allocator, words, false),
        .pascal => try buildCamelCase(allocator, words, true),
        .upper => unreachable,
    };
}

/// Join words with a separator character, appending a newline.
fn joinWith(allocator: std.mem.Allocator, words: [][]u8, sep: u8) ![]u8 {
    var total_len: usize = 0;
    for (words) |w| {
        total_len += w.len;
    }
    total_len += words.len - 1; // separators
    total_len += 1; // newline

    const result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    for (words, 0..) |w, i| {
        @memcpy(result[pos .. pos + w.len], w);
        pos += w.len;
        if (i < words.len - 1) {
            result[pos] = sep;
            pos += 1;
        }
    }
    result[pos] = '\n';
    return result;
}

/// Build camelCase or PascalCase from word list, appending a newline.
fn buildCamelCase(allocator: std.mem.Allocator, words: [][]u8, capitalize_first: bool) ![]u8 {
    var total_len: usize = 0;
    for (words) |w| {
        total_len += w.len;
    }
    total_len += 1; // newline

    const result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    for (words, 0..) |w, i| {
        if (w.len == 0) continue;
        @memcpy(result[pos .. pos + w.len], w);
        if (i == 0 and capitalize_first) {
            result[pos] = std.ascii.toUpper(w[0]);
        } else if (i > 0) {
            result[pos] = std.ascii.toUpper(w[0]);
        }
        pos += w.len;
    }
    result[pos] = '\n';
    return result;
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "strcase",
    .description = "Convert string between cases (snake, camel, pascal, kebab, upper)",
    .category = .encoding,
    .subcommands = &.{ "snake", "camel", "pascal", "kebab", "upper" },
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_strcase_out.tmp";

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

fn trimResult(output: []const u8) []const u8 {
    return std.mem.trimRight(u8, output, &std.ascii.whitespace);
}

test "strcase snake from camelCase" {
    const output = try execWithInput("helloWorld", "snake");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("hello_world", trimResult(output));
}

test "strcase snake from PascalCase" {
    const output = try execWithInput("HelloWorld", "snake");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("hello_world", trimResult(output));
}

test "strcase snake from kebab-case" {
    const output = try execWithInput("hello-world", "snake");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("hello_world", trimResult(output));
}

test "strcase camel from snake_case" {
    const output = try execWithInput("hello_world", "camel");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("helloWorld", trimResult(output));
}

test "strcase camel from PascalCase" {
    const output = try execWithInput("HelloWorld", "camel");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("helloWorld", trimResult(output));
}

test "strcase pascal from snake_case" {
    const output = try execWithInput("hello_world", "pascal");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("HelloWorld", trimResult(output));
}

test "strcase pascal from camelCase" {
    const output = try execWithInput("helloWorld", "pascal");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("HelloWorld", trimResult(output));
}

test "strcase kebab from snake_case" {
    const output = try execWithInput("hello_world", "kebab");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("hello-world", trimResult(output));
}

test "strcase kebab from camelCase" {
    const output = try execWithInput("helloWorld", "kebab");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("hello-world", trimResult(output));
}

test "strcase upper" {
    const output = try execWithInput("hello world", "upper");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("HELLO WORLD", trimResult(output));
}

test "strcase upper preserves separators" {
    const output = try execWithInput("hello_world-foo", "upper");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("HELLO_WORLD-FOO", trimResult(output));
}

test "strcase snake multi-word" {
    const output = try execWithInput("myVariableName", "snake");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("my_variable_name", trimResult(output));
}

test "strcase unknown subcommand" {
    const result = execWithInput("test", "rot13");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "strcase missing subcommand" {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_strcase_nosub.tmp";
    const out_file = try std.fs.cwd().createFile(tmp_out, .{});

    const args = [_][]const u8{"test"};
    var ctx = context.Context.initDefault(allocator);
    ctx.args = &args;
    ctx.stdout = out_file;

    const result = execute(ctx, null);
    out_file.close();
    std.fs.cwd().deleteFile(tmp_out) catch {};
    try std.testing.expectError(error.MissingArgument, result);
}

test "strcase command struct fields" {
    try std.testing.expectEqualStrings("strcase", command.name);
    try std.testing.expectEqual(registry.Category.encoding, command.category);
    try std.testing.expectEqual(@as(usize, 5), command.subcommands.len);
}
