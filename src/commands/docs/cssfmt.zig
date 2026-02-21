const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// Format CSS with consistent indentation and one property per line.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    if (subcommand) |sub| {
        const writer = ctx.stderrWriter();
        try writer.print("cssfmt: unknown subcommand '{s}'\n", .{sub});
        return error.InvalidArgument;
    }

    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("cssfmt: no input provided\n", .{});
        try writer.print("Usage: zuxi cssfmt <css-data>\n", .{});
        try writer.print("       echo 'body{{color:red}}' | zuxi cssfmt\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    const result = try formatCss(ctx.allocator, input.data);
    defer ctx.allocator.free(result);

    try io.writeOutput(ctx, result);
}

/// Format CSS source with consistent indentation.
pub fn formatCss(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    var depth: usize = 0;
    var i: usize = 0;
    var line_start = true;
    var in_string: u8 = 0; // 0 = none, '\'' or '"'
    var in_comment = false;
    var in_line_start_ws = true; // track leading whitespace to skip

    while (i < src.len) {
        // Handle CSS comments /* ... */
        if (in_comment) {
            if (i + 1 < src.len and src[i] == '*' and src[i + 1] == '/') {
                try out.appendSlice(allocator, "*/");
                try out.append(allocator, '\n');
                i += 2;
                in_comment = false;
                line_start = true;
                in_line_start_ws = true;
                continue;
            }
            try out.append(allocator, src[i]);
            if (src[i] == '\n') {
                line_start = true;
                in_line_start_ws = true;
            }
            i += 1;
            continue;
        }

        // Start of comment
        if (in_string == 0 and i + 1 < src.len and src[i] == '/' and src[i + 1] == '*') {
            if (!line_start) {
                try out.append(allocator, '\n');
            }
            try writeIndent(allocator, &out, depth);
            try out.appendSlice(allocator, "/*");
            i += 2;
            in_comment = true;
            line_start = false;
            in_line_start_ws = false;
            continue;
        }

        // Handle strings
        if (in_string != 0) {
            try out.append(allocator, src[i]);
            if (src[i] == in_string and (i == 0 or src[i - 1] != '\\')) {
                in_string = 0;
            }
            i += 1;
            continue;
        }

        if (src[i] == '"' or src[i] == '\'') {
            if (in_line_start_ws and line_start) {
                try writeIndent(allocator, &out, depth);
                line_start = false;
                in_line_start_ws = false;
            }
            in_string = src[i];
            try out.append(allocator, src[i]);
            i += 1;
            continue;
        }

        // Skip leading whitespace on lines (we re-indent ourselves)
        if (in_line_start_ws and (src[i] == ' ' or src[i] == '\t')) {
            i += 1;
            continue;
        }
        if (in_line_start_ws and src[i] == '\n') {
            i += 1;
            continue;
        }
        in_line_start_ws = false;

        switch (src[i]) {
            '{' => {
                // Trim trailing whitespace before brace
                trimTrailingWs(allocator, &out);
                if (line_start) {
                    try writeIndent(allocator, &out, depth);
                } else {
                    // Ensure space before {
                    if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') {
                        try out.append(allocator, ' ');
                    }
                }
                try out.append(allocator, '{');
                try out.append(allocator, '\n');
                depth += 1;
                line_start = true;
                in_line_start_ws = true;
                i += 1;
            },
            '}' => {
                trimTrailingWs(allocator, &out);
                if (!line_start) {
                    // Content on current line before }, add newline
                    try out.append(allocator, '\n');
                }
                if (depth > 0) depth -= 1;
                try writeIndent(allocator, &out, depth);
                try out.append(allocator, '}');
                try out.append(allocator, '\n');
                line_start = true;
                in_line_start_ws = true;
                i += 1;
            },
            ';' => {
                trimTrailingWs(allocator, &out);
                try out.append(allocator, ';');
                try out.append(allocator, '\n');
                line_start = true;
                in_line_start_ws = true;
                i += 1;
            },
            '\n', '\r' => {
                // Skip extra newlines; we handle newlines via ; and {}
                i += 1;
                if (!line_start) {
                    // Content was on this line without a semicolon - keep going
                }
                continue;
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

fn trimTrailingWs(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) void {
    _ = allocator;
    while (out.items.len > 0) {
        const last = out.items[out.items.len - 1];
        if (last == ' ' or last == '\t') {
            out.items.len -= 1;
        } else {
            break;
        }
    }
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "cssfmt",
    .description = "Format CSS with consistent indentation",
    .category = .docs,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_cssfmt_out.tmp";

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

test "cssfmt simple rule" {
    const output = try execWithInput("body{color:red;margin:0}", null);
    defer std.testing.allocator.free(output);

    const expected =
        "body {\n" ++
        "  color:red;\n" ++
        "  margin:0\n" ++
        "}\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "cssfmt nested rules" {
    const output = try execWithInput(".parent{.child{color:blue;}}", null);
    defer std.testing.allocator.free(output);

    const expected =
        ".parent {\n" ++
        "  .child {\n" ++
        "    color:blue;\n" ++
        "  }\n" ++
        "}\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "cssfmt already formatted" {
    const input =
        "body {\n" ++
        "  color: red;\n" ++
        "}\n";
    const output = try execWithInput(input, null);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings(input, output);
}

test "cssfmt multiple selectors" {
    const output = try execWithInput("a{color:red;}b{color:blue;}", null);
    defer std.testing.allocator.free(output);

    const expected =
        "a {\n" ++
        "  color:red;\n" ++
        "}\n" ++
        "b {\n" ++
        "  color:blue;\n" ++
        "}\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "cssfmt unknown subcommand" {
    const result = execWithInput("body{}", "foo");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "cssfmt command struct" {
    try std.testing.expectEqualStrings("cssfmt", command.name);
    try std.testing.expectEqual(registry.Category.docs, command.category);
}
