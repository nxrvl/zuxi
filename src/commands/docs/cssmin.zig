const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// Minify CSS by stripping comments, collapsing whitespace, and removing unnecessary chars.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    if (subcommand) |sub| {
        const writer = ctx.stderrWriter();
        try writer.print("cssmin: unknown subcommand '{s}'\n", .{sub});
        return error.InvalidArgument;
    }

    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("cssmin: no input provided\n", .{});
        try writer.print("Usage: zuxi cssmin <css-data>\n", .{});
        try writer.print("       echo 'body {{ color: red; }}' | zuxi cssmin\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    const result = try minifyCss(ctx.allocator, input.data);
    defer ctx.allocator.free(result);

    try io.writeOutput(ctx, result);
}

/// Minify CSS source.
pub fn minifyCss(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    var i: usize = 0;
    var in_string: u8 = 0;
    var last_was_space = false;

    while (i < src.len) {
        // Handle strings
        if (in_string != 0) {
            try out.append(allocator, src[i]);
            if (src[i] == in_string) {
                // Count consecutive preceding backslashes; odd means quote is escaped.
                var bs: usize = 0;
                var j = i;
                while (j > 0 and src[j - 1] == '\\') {
                    bs += 1;
                    j -= 1;
                }
                if (bs % 2 == 0) {
                    in_string = 0;
                }
            }
            i += 1;
            last_was_space = false;
            continue;
        }

        // Strip comments /* ... */
        if (i + 1 < src.len and src[i] == '/' and src[i + 1] == '*') {
            i += 2;
            while (i + 1 < src.len) {
                if (src[i] == '*' and src[i + 1] == '/') {
                    i += 2;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // Start string
        if (src[i] == '"' or src[i] == '\'') {
            in_string = src[i];
            try out.append(allocator, src[i]);
            i += 1;
            last_was_space = false;
            continue;
        }

        // Collapse whitespace
        if (src[i] == ' ' or src[i] == '\t' or src[i] == '\n' or src[i] == '\r') {
            i += 1;
            if (!last_was_space and out.items.len > 0) {
                // Check if space can be eliminated (around structural chars)
                // We'll add a space placeholder and remove it later if not needed
                last_was_space = true;
            }
            continue;
        }

        // Before emitting a non-ws char, decide if pending space is needed
        if (last_was_space) {
            last_was_space = false;
            // Space is not needed around: { } ; : , > + ~ ( )
            const no_space_before = "{}:;,>+~()";
            const no_space_after = "{}:;,>+~()";
            const need_space = blk: {
                if (out.items.len == 0) break :blk false;
                const prev = out.items[out.items.len - 1];
                for (no_space_after) |c| {
                    if (prev == c) break :blk false;
                }
                for (no_space_before) |c| {
                    if (src[i] == c) break :blk false;
                }
                break :blk true;
            };
            if (need_space) {
                try out.append(allocator, ' ');
            }
        }

        // Remove last semicolon before }
        if (src[i] == '}') {
            if (out.items.len > 0 and out.items[out.items.len - 1] == ';') {
                out.items.len -= 1;
            }
        }

        try out.append(allocator, src[i]);
        i += 1;
        last_was_space = false;
    }

    // Ensure trailing newline
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
        try out.append(allocator, '\n');
    }

    return try out.toOwnedSlice(allocator);
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "cssmin",
    .description = "Minify CSS by removing comments and whitespace",
    .category = .docs,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_cssmin_out.tmp";

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

test "cssmin simple" {
    const input =
        "body {\n" ++
        "  color: red;\n" ++
        "  margin: 0;\n" ++
        "}\n";
    const output = try execWithInput(input, null);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("body{color:red;margin:0}\n", output);
}

test "cssmin strips comments" {
    const input = "/* comment */body{color:red;}";
    const output = try execWithInput(input, null);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("body{color:red}\n", output);
}

test "cssmin preserves strings" {
    const input = "a{content:\"hello world\"}";
    const output = try execWithInput(input, null);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("a{content:\"hello world\"}\n", output);
}

test "cssmin removes last semicolon" {
    const input = "a { color: red; }";
    const output = try execWithInput(input, null);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("a{color:red}\n", output);
}

test "cssmin multiple rules" {
    const input = "a { color: red; }\nb { margin: 0; }";
    const output = try execWithInput(input, null);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("a{color:red}b{margin:0}\n", output);
}

test "cssmin unknown subcommand" {
    const result = execWithInput("body{}", "foo");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "cssmin command struct" {
    try std.testing.expectEqualStrings("cssmin", command.name);
    try std.testing.expectEqual(registry.Category.docs, command.category);
}
