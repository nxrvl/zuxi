const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// Format GraphQL queries with consistent indentation.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    if (subcommand) |sub| {
        const writer = ctx.stderrWriter();
        try writer.print("gqlquery: unknown subcommand '{s}'\n", .{sub});
        return error.InvalidArgument;
    }

    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("gqlquery: no input provided\n", .{});
        try writer.print("Usage: zuxi gqlquery <graphql-query>\n", .{});
        try writer.print("       echo '{{user{{name}}}}' | zuxi gqlquery\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    const result = try formatGraphql(ctx.allocator, input.data);
    defer ctx.allocator.free(result);

    try io.writeOutput(ctx, result);
}

/// Format GraphQL query source with consistent indentation.
pub fn formatGraphql(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    var depth: usize = 0;
    var paren_depth: usize = 0;
    var i: usize = 0;
    var line_start = true;
    var in_string = false;

    while (i < src.len) {
        // Handle strings
        if (in_string) {
            try out.append(allocator, src[i]);
            if (src[i] == '"') {
                // Count consecutive preceding backslashes; odd means quote is escaped.
                var bs: usize = 0;
                var j = i;
                while (j > 0 and src[j - 1] == '\\') {
                    bs += 1;
                    j -= 1;
                }
                if (bs % 2 == 0) {
                    in_string = false;
                }
            }
            i += 1;
            continue;
        }

        if (src[i] == '"') {
            if (line_start) {
                try writeIndent(allocator, &out, depth);
                line_start = false;
            }
            in_string = true;
            try out.append(allocator, src[i]);
            i += 1;
            continue;
        }

        // Handle comments (# to end of line)
        if (src[i] == '#') {
            if (line_start) {
                try writeIndent(allocator, &out, depth);
                line_start = false;
            }
            while (i < src.len and src[i] != '\n') {
                try out.append(allocator, src[i]);
                i += 1;
            }
            try out.append(allocator, '\n');
            line_start = true;
            if (i < src.len) i += 1;
            continue;
        }

        // Skip whitespace (we re-indent ourselves)
        if (src[i] == ' ' or src[i] == '\t' or src[i] == '\n' or src[i] == '\r') {
            if (!line_start) {
                // Check if next non-ws char is { or ( - no space needed
                const next = nextNonWs(src, i + 1);
                if (next < src.len and (src[next] == '{' or src[next] == '(' or src[next] == '}' or src[next] == ')')) {
                    i += 1;
                    continue;
                }
                // Inside braces but outside parens: fields go on separate lines
                if (depth > 0 and paren_depth == 0) {
                    try out.append(allocator, '\n');
                    line_start = true;
                } else {
                    // Inside parens or at top level: collapse to single space
                    if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') {
                        try out.append(allocator, ' ');
                    }
                }
            }
            i += 1;
            continue;
        }

        switch (src[i]) {
            '{' => {
                // Trim trailing space before {
                if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
                    out.items.len -= 1;
                }
                if (line_start) {
                    try writeIndent(allocator, &out, depth);
                } else {
                    // Ensure space before {
                    if (out.items.len > 0 and out.items[out.items.len - 1] != ' ' and out.items[out.items.len - 1] != '(') {
                        try out.append(allocator, ' ');
                    }
                }
                try out.append(allocator, '{');
                try out.append(allocator, '\n');
                depth += 1;
                line_start = true;
                i += 1;
            },
            '}' => {
                // Trim trailing whitespace
                while (out.items.len > 0 and (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '\t')) {
                    out.items.len -= 1;
                }
                if (depth > 0) depth -= 1;
                if (!line_start) {
                    try out.append(allocator, '\n');
                }
                try writeIndent(allocator, &out, depth);
                try out.append(allocator, '}');
                try out.append(allocator, '\n');
                line_start = true;
                i += 1;
            },
            '(' => {
                if (line_start) {
                    try writeIndent(allocator, &out, depth);
                    line_start = false;
                }
                // Remove trailing space before (
                if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
                    out.items.len -= 1;
                }
                try out.append(allocator, '(');
                paren_depth += 1;
                i += 1;
            },
            ')' => {
                // Remove trailing space before )
                if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
                    out.items.len -= 1;
                }
                try out.append(allocator, ')');
                if (paren_depth > 0) paren_depth -= 1;
                i += 1;
            },
            ',' => {
                try out.append(allocator, ',');
                try out.append(allocator, ' ');
                i += 1;
            },
            ':' => {
                // Remove trailing space before :
                if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
                    out.items.len -= 1;
                }
                try out.append(allocator, ':');
                try out.append(allocator, ' ');
                i += 1;
            },
            else => {
                if (line_start) {
                    try writeIndent(allocator, &out, depth);
                    line_start = false;
                }
                try out.append(allocator, src[i]);
                i += 1;
            },
        }
    }

    // Ensure trailing newline
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
        try out.append(allocator, '\n');
    }

    return try out.toOwnedSlice(allocator);
}

fn writeIndent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize) !void {
    for (0..depth) |_| {
        try out.appendSlice(allocator, "  ");
    }
}

fn nextNonWs(src: []const u8, start: usize) usize {
    var j = start;
    while (j < src.len) : (j += 1) {
        if (src[j] != ' ' and src[j] != '\t' and src[j] != '\n' and src[j] != '\r') return j;
    }
    return src.len;
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "gqlquery",
    .description = "Format GraphQL queries with consistent indentation",
    .category = .docs,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_gqlquery_out.tmp";

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

test "gqlquery simple query" {
    const output = try execWithInput("{user{name age}}", null);
    defer std.testing.allocator.free(output);

    const expected =
        "{\n" ++
        "  user {\n" ++
        "    name\n" ++
        "    age\n" ++
        "  }\n" ++
        "}\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "gqlquery with arguments" {
    const output = try execWithInput("query{user(id:1){name}}", null);
    defer std.testing.allocator.free(output);

    const expected =
        "query {\n" ++
        "  user(id: 1) {\n" ++
        "    name\n" ++
        "  }\n" ++
        "}\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "gqlquery mutation" {
    const output = try execWithInput("mutation{createUser(name:\"Alice\"){id name}}", null);
    defer std.testing.allocator.free(output);

    const expected =
        "mutation {\n" ++
        "  createUser(name: \"Alice\") {\n" ++
        "    id\n" ++
        "    name\n" ++
        "  }\n" ++
        "}\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "gqlquery already formatted" {
    const input =
        "query {\n" ++
        "  user {\n" ++
        "    name\n" ++
        "  }\n" ++
        "}\n";
    const output = try execWithInput(input, null);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings(input, output);
}

test "gqlquery unknown subcommand" {
    const result = execWithInput("{user{name}}", "foo");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "gqlquery command struct" {
    try std.testing.expectEqualStrings("gqlquery", command.name);
    try std.testing.expectEqual(registry.Category.docs, command.category);
}
