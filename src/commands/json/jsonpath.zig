const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");
const color = @import("../../core/color.zig");

/// Entry point for the jsonpath command.
pub fn execute(ctx: context.Context, _: ?[]const u8) anyerror!void {
    // Need at least a path expression, and optionally JSON data.
    if (ctx.args.len < 1) {
        const writer = ctx.stderrWriter();
        try writer.print("jsonpath: no path expression provided\n", .{});
        try writer.print("Usage: zuxi jsonpath <path> <json>\n", .{});
        try writer.print("       echo '{{...}}' | zuxi jsonpath <path>\n", .{});
        try writer.print("Paths: $.key, $.nested.key, $.array[0], $.array[*].field\n", .{});
        return error.MissingArgument;
    }

    const path_expr = ctx.args[0];
    var json_data: []const u8 = undefined;
    var allocated = false;

    if (ctx.args.len >= 2) {
        json_data = ctx.args[1];
    } else if (!io.isTty(ctx.stdin)) {
        const data = try io.readAllTrimmed(ctx.stdin, ctx.allocator);
        json_data = data;
        allocated = true;
    } else {
        const writer = ctx.stderrWriter();
        try writer.print("jsonpath: no JSON input provided\n", .{});
        return error.MissingArgument;
    }
    defer if (allocated) ctx.allocator.free(@constCast(json_data));

    // Parse the JSON.
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, json_data, .{}) catch {
        const writer = ctx.stderrWriter();
        try writer.print("jsonpath: invalid JSON input\n", .{});
        return error.FormatError;
    };
    defer parsed.deinit();

    // Parse the path expression.
    const segments = parsePath(ctx.allocator, path_expr) catch {
        const writer = ctx.stderrWriter();
        try writer.print("jsonpath: invalid path expression '{s}'\n", .{path_expr});
        return error.InvalidArgument;
    };
    defer ctx.allocator.free(segments);

    // Query the JSON.
    var results = std.ArrayList(std.json.Value){};
    defer results.deinit(ctx.allocator);
    try queryJson(ctx.allocator, parsed.value, segments, &results);

    if (results.items.len == 0) {
        const writer = ctx.stderrWriter();
        try writer.print("jsonpath: no match for path '{s}'\n", .{path_expr});
        return error.InvalidInput;
    }

    // Output results.
    const no_color = !color.shouldColor(ctx);
    const stdout = ctx.stdoutWriter();
    for (results.items) |value| {
        const json_str = std.json.Stringify.valueAlloc(ctx.allocator, value, .{
            .whitespace = .indent_4,
        }) catch return error.OutOfMemory;
        defer ctx.allocator.free(json_str);

        if (!no_color) {
            try color.writeColoredJson(stdout, json_str, false);
        } else {
            try stdout.writeAll(json_str);
        }
        try stdout.writeByte('\n');
    }
}

/// A segment in a JSON path expression.
const PathSegment = union(enum) {
    /// Access an object key by name.
    key: []const u8,
    /// Access an array element by index.
    index: usize,
    /// Wildcard - iterate all elements of array/object.
    wildcard,
};

/// Parse a dot-notation path expression like "$.key.nested[0].field[*]".
fn parsePath(allocator: std.mem.Allocator, expr: []const u8) ![]PathSegment {
    var segments = std.ArrayList(PathSegment){};
    defer segments.deinit(allocator);

    var input = expr;

    // Strip leading '$'.
    if (input.len > 0 and input[0] == '$') {
        input = input[1..];
    }

    // Strip leading '.'.
    if (input.len > 0 and input[0] == '.') {
        input = input[1..];
    }

    if (input.len == 0) {
        // "$" alone means the root.
        return try segments.toOwnedSlice(allocator);
    }

    while (input.len > 0) {
        if (input[0] == '[') {
            // Array index or wildcard.
            const close = std.mem.indexOfScalar(u8, input, ']') orelse return error.InvalidPath;
            const inside = input[1..close];
            if (std.mem.eql(u8, inside, "*")) {
                try segments.append(allocator, .wildcard);
            } else {
                const idx = std.fmt.parseInt(usize, inside, 10) catch return error.InvalidPath;
                try segments.append(allocator, .{ .index = idx });
            }
            input = input[close + 1 ..];
            // Skip dot after bracket.
            if (input.len > 0 and input[0] == '.') {
                input = input[1..];
            }
        } else {
            // Key name - read until '.' or '[' or end.
            var end: usize = 0;
            while (end < input.len and input[end] != '.' and input[end] != '[') : (end += 1) {}
            if (end == 0) return error.InvalidPath;
            try segments.append(allocator, .{ .key = input[0..end] });
            input = input[end..];
            if (input.len > 0 and input[0] == '.') {
                input = input[1..];
            }
        }
    }

    return try segments.toOwnedSlice(allocator);
}

/// Query a JSON value with the parsed path segments, collecting results.
fn queryJson(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    segments: []const PathSegment,
    results: *std.ArrayList(std.json.Value),
) !void {
    if (segments.len == 0) {
        try results.append(allocator, value);
        return;
    }

    const seg = segments[0];
    const rest = segments[1..];

    switch (seg) {
        .key => |key| {
            switch (value) {
                .object => |obj| {
                    if (obj.get(key)) |child| {
                        try queryJson(allocator, child, rest, results);
                    }
                },
                else => {},
            }
        },
        .index => |idx| {
            switch (value) {
                .array => |arr| {
                    if (idx < arr.items.len) {
                        try queryJson(allocator, arr.items[idx], rest, results);
                    }
                },
                else => {},
            }
        },
        .wildcard => {
            switch (value) {
                .array => |arr| {
                    for (arr.items) |item| {
                        try queryJson(allocator, item, rest, results);
                    }
                },
                .object => |obj| {
                    var it = obj.iterator();
                    while (it.next()) |entry| {
                        try queryJson(allocator, entry.value_ptr.*, rest, results);
                    }
                },
                else => {},
            }
        },
    }
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "jsonpath",
    .description = "Query JSON with dot-notation paths",
    .category = .json,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithArgs(args: []const []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_jsonpath_out.tmp";

    const out_file = try std.fs.cwd().createFile(tmp_out, .{});

    var ctx = context.Context.initDefault(allocator);
    ctx.args = args;
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

test "jsonpath simple key" {
    const args = [_][]const u8{ "$.name", "{\"name\": \"zuxi\", \"version\": 1}" };
    const output = try execWithArgs(&args);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("\"zuxi\"", trimmed);
}

test "jsonpath nested key" {
    const args = [_][]const u8{ "$.a.b", "{\"a\": {\"b\": 42}}" };
    const output = try execWithArgs(&args);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("42", trimmed);
}

test "jsonpath array index" {
    const args = [_][]const u8{ "$.items[1]", "{\"items\": [10, 20, 30]}" };
    const output = try execWithArgs(&args);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("20", trimmed);
}

test "jsonpath wildcard array" {
    const args = [_][]const u8{ "$.items[*].name", "{\"items\": [{\"name\": \"a\"}, {\"name\": \"b\"}]}" };
    const output = try execWithArgs(&args);
    defer std.testing.allocator.free(output);
    // Should have both "a" and "b".
    try std.testing.expect(std.mem.indexOf(u8, output, "\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"b\"") != null);
}

test "jsonpath root selector" {
    const args = [_][]const u8{ "$", "{\"key\": \"val\"}" };
    const output = try execWithArgs(&args);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"val\"") != null);
}

test "jsonpath no match" {
    const args = [_][]const u8{ "$.missing", "{\"key\": \"val\"}" };
    const result = execWithArgs(&args);
    try std.testing.expectError(error.InvalidInput, result);
}

test "jsonpath invalid JSON" {
    const args = [_][]const u8{ "$.key", "not json" };
    const result = execWithArgs(&args);
    try std.testing.expectError(error.FormatError, result);
}

test "jsonpath no args" {
    const args = [_][]const u8{};
    var ctx = context.Context.initDefault(std.testing.allocator);
    ctx.args = &args;

    const tmp_out = "zuxi_test_jsonpath_noargs.tmp";
    const out_file = try std.fs.cwd().createFile(tmp_out, .{});
    ctx.stdout = out_file;

    const result = execute(ctx, null);
    out_file.close();
    std.fs.cwd().deleteFile(tmp_out) catch {};
    try std.testing.expectError(error.MissingArgument, result);
}

test "jsonpath deeply nested" {
    const args = [_][]const u8{ "$.a.b.c.d", "{\"a\": {\"b\": {\"c\": {\"d\": \"deep\"}}}}" };
    const output = try execWithArgs(&args);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("\"deep\"", trimmed);
}

test "jsonpath array first element" {
    const args = [_][]const u8{ "$.data[0]", "{\"data\": [\"first\", \"second\"]}" };
    const output = try execWithArgs(&args);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("\"first\"", trimmed);
}

test "jsonpath returns object" {
    const args = [_][]const u8{ "$.config", "{\"config\": {\"debug\": true}}" };
    const output = try execWithArgs(&args);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"debug\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "true") != null);
}

test "jsonpath no ANSI codes in file output" {
    const args = [_][]const u8{ "$.key", "{\"key\": \"value\"}" };
    const output = try execWithArgs(&args);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
}

test "jsonpath command struct fields" {
    try std.testing.expectEqualStrings("jsonpath", command.name);
    try std.testing.expectEqual(registry.Category.json, command.category);
}

test "parsePath simple key" {
    const allocator = std.testing.allocator;
    const segments = try parsePath(allocator, "$.name");
    defer allocator.free(segments);
    try std.testing.expectEqual(@as(usize, 1), segments.len);
    try std.testing.expectEqualStrings("name", segments[0].key);
}

test "parsePath nested" {
    const allocator = std.testing.allocator;
    const segments = try parsePath(allocator, "$.a.b.c");
    defer allocator.free(segments);
    try std.testing.expectEqual(@as(usize, 3), segments.len);
    try std.testing.expectEqualStrings("a", segments[0].key);
    try std.testing.expectEqualStrings("b", segments[1].key);
    try std.testing.expectEqualStrings("c", segments[2].key);
}

test "parsePath with index" {
    const allocator = std.testing.allocator;
    const segments = try parsePath(allocator, "$.items[0]");
    defer allocator.free(segments);
    try std.testing.expectEqual(@as(usize, 2), segments.len);
    try std.testing.expectEqualStrings("items", segments[0].key);
    try std.testing.expectEqual(@as(usize, 0), segments[1].index);
}

test "parsePath with wildcard" {
    const allocator = std.testing.allocator;
    const segments = try parsePath(allocator, "$.items[*].name");
    defer allocator.free(segments);
    try std.testing.expectEqual(@as(usize, 3), segments.len);
    try std.testing.expectEqualStrings("items", segments[0].key);
    try std.testing.expect(segments[1] == .wildcard);
    try std.testing.expectEqualStrings("name", segments[2].key);
}
