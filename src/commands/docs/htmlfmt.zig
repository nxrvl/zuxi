const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// Format HTML with consistent indentation for nested tags.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    if (subcommand) |sub| {
        const writer = ctx.stderrWriter();
        try writer.print("htmlfmt: unknown subcommand '{s}'\n", .{sub});
        return error.InvalidArgument;
    }

    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("htmlfmt: no input provided\n", .{});
        try writer.print("Usage: zuxi htmlfmt <html-data>\n", .{});
        try writer.print("       echo '<div><p>hi</p></div>' | zuxi htmlfmt\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    const result = try formatHtml(ctx.allocator, input.data);
    defer ctx.allocator.free(result);

    try io.writeOutput(ctx, result);
}

/// Tags that are self-closing (void elements).
const void_elements = [_][]const u8{
    "area", "base", "br", "col", "embed", "hr", "img", "input",
    "link", "meta", "param", "source", "track", "wbr",
};

/// Tags whose content should be preserved inline.
const inline_elements = [_][]const u8{
    "a", "abbr", "b", "bdi", "bdo", "cite", "code", "data", "em",
    "i", "kbd", "mark", "q", "s", "samp", "small", "span", "strong",
    "sub", "sup", "time", "u", "var",
};

/// Tags that contain raw content (not parsed as HTML).
const raw_elements = [_][]const u8{ "script", "style", "pre", "code", "textarea" };

fn isVoidElement(name: []const u8) bool {
    for (void_elements) |v| {
        if (std.ascii.eqlIgnoreCase(v, name)) return true;
    }
    return false;
}

fn isRawElement(name: []const u8) bool {
    for (raw_elements) |v| {
        if (std.ascii.eqlIgnoreCase(v, name)) return true;
    }
    return false;
}

/// Format HTML source with consistent indentation.
pub fn formatHtml(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    var depth: usize = 0;
    var i: usize = 0;

    while (i < src.len) {
        // Skip whitespace between tags
        if (isWs(src[i])) {
            i += 1;
            continue;
        }

        if (src[i] == '<') {
            // Comment <!-- ... -->
            if (i + 3 < src.len and src[i + 1] == '!' and src[i + 2] == '-' and src[i + 3] == '-') {
                try writeIndent(allocator, &out, depth);
                const end = findCommentEnd(src, i + 4);
                try out.appendSlice(allocator, src[i..end]);
                try out.append(allocator, '\n');
                i = end;
                continue;
            }

            // DOCTYPE
            if (i + 1 < src.len and src[i + 1] == '!') {
                try writeIndent(allocator, &out, depth);
                const end = findCharFrom(src, i, '>');
                try out.appendSlice(allocator, src[i .. end + 1]);
                try out.append(allocator, '\n');
                i = end + 1;
                continue;
            }

            // Closing tag </...>
            if (i + 1 < src.len and src[i + 1] == '/') {
                const tag_end = findCharFrom(src, i, '>');
                const tag_name = extractTagName(src[i + 2 .. tag_end]);
                _ = tag_name;
                if (depth > 0) depth -= 1;
                try writeIndent(allocator, &out, depth);
                try out.appendSlice(allocator, src[i .. tag_end + 1]);
                try out.append(allocator, '\n');
                i = tag_end + 1;
                continue;
            }

            // Opening tag or self-closing tag
            const tag_end = findCharFrom(src, i, '>');
            const tag_content = src[i + 1 .. tag_end];
            const tag_name = extractTagName(tag_content);
            const self_closing = tag_end > 0 and src[tag_end - 1] == '/';
            const is_void = isVoidElement(tag_name);
            const is_raw = isRawElement(tag_name);

            try writeIndent(allocator, &out, depth);
            try out.appendSlice(allocator, src[i .. tag_end + 1]);

            if (self_closing or is_void) {
                try out.append(allocator, '\n');
                i = tag_end + 1;
                continue;
            }

            if (is_raw) {
                // For raw elements, find the closing tag and output content as-is
                i = tag_end + 1;
                const close_tag = findClosingTag(src, i, tag_name);
                if (close_tag.start != close_tag.end) {
                    try out.append(allocator, '\n');
                    // Preserve raw content with indentation
                    depth += 1;
                    const raw_content = std.mem.trim(u8, src[i..close_tag.start], &std.ascii.whitespace);
                    if (raw_content.len > 0) {
                        try writeIndent(allocator, &out, depth);
                        try out.appendSlice(allocator, raw_content);
                        try out.append(allocator, '\n');
                    }
                    depth -= 1;
                    try writeIndent(allocator, &out, depth);
                    try out.appendSlice(allocator, src[close_tag.start..close_tag.end]);
                    try out.append(allocator, '\n');
                    i = close_tag.end;
                } else {
                    try out.append(allocator, '\n');
                    depth += 1;
                }
                continue;
            }

            // Check if there's inline text content before next tag
            i = tag_end + 1;
            const next_tag = findNextTag(src, i);
            const between = src[i..next_tag];
            const trimmed = std.mem.trim(u8, between, &std.ascii.whitespace);

            if (trimmed.len > 0 and next_tag < src.len and src[next_tag] == '<' and next_tag + 1 < src.len and src[next_tag + 1] == '/') {
                // Inline content: <tag>text</tag> on one line
                const close_end = findCharFrom(src, next_tag, '>');
                try out.appendSlice(allocator, trimmed);
                try out.appendSlice(allocator, src[next_tag .. close_end + 1]);
                try out.append(allocator, '\n');
                i = close_end + 1;
                continue;
            }

            try out.append(allocator, '\n');
            depth += 1;

            // If there's text content, output it indented
            if (trimmed.len > 0) {
                try writeIndent(allocator, &out, depth);
                try out.appendSlice(allocator, trimmed);
                try out.append(allocator, '\n');
                i = next_tag;
            }

            continue;
        }

        // Text content outside tags
        const next_tag = findNextTag(src, i);
        const text = std.mem.trim(u8, src[i..next_tag], &std.ascii.whitespace);
        if (text.len > 0) {
            try writeIndent(allocator, &out, depth);
            try out.appendSlice(allocator, text);
            try out.append(allocator, '\n');
        }
        i = next_tag;
    }

    // Ensure trailing newline
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
        try out.append(allocator, '\n');
    }

    return try out.toOwnedSlice(allocator);
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn writeIndent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize) !void {
    for (0..depth) |_| {
        try out.appendSlice(allocator, "  ");
    }
}

fn findCharFrom(src: []const u8, start: usize, char: u8) usize {
    var j = start;
    while (j < src.len) : (j += 1) {
        if (src[j] == char) return j;
    }
    return src.len;
}

fn findCommentEnd(src: []const u8, start: usize) usize {
    var j = start;
    while (j + 2 < src.len) : (j += 1) {
        if (src[j] == '-' and src[j + 1] == '-' and src[j + 2] == '>') {
            return j + 3;
        }
    }
    return src.len;
}

fn extractTagName(tag_content: []const u8) []const u8 {
    var end: usize = 0;
    while (end < tag_content.len) : (end += 1) {
        const c = tag_content[end];
        if (c == ' ' or c == '\t' or c == '\n' or c == '/' or c == '>') break;
    }
    return tag_content[0..end];
}

fn findNextTag(src: []const u8, start: usize) usize {
    var j = start;
    while (j < src.len) : (j += 1) {
        if (src[j] == '<') return j;
    }
    return src.len;
}

const TagRange = struct {
    start: usize,
    end: usize,
};

fn findClosingTag(src: []const u8, start: usize, tag_name: []const u8) TagRange {
    var j = start;
    while (j + 2 + tag_name.len < src.len) : (j += 1) {
        if (src[j] == '<' and src[j + 1] == '/') {
            const name_start = j + 2;
            const name_end = name_start + tag_name.len;
            if (name_end <= src.len and std.ascii.eqlIgnoreCase(src[name_start..name_end], tag_name)) {
                const close = findCharFrom(src, name_end, '>');
                return .{ .start = j, .end = close + 1 };
            }
        }
    }
    return .{ .start = start, .end = start };
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "htmlfmt",
    .description = "Format HTML with consistent indentation",
    .category = .docs,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_htmlfmt_out.tmp";

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

test "htmlfmt simple nesting" {
    const output = try execWithInput("<div><p>hello</p></div>", null);
    defer std.testing.allocator.free(output);

    const expected =
        "<div>\n" ++
        "  <p>hello</p>\n" ++
        "</div>\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "htmlfmt self-closing tags" {
    const output = try execWithInput("<div><br/><hr/></div>", null);
    defer std.testing.allocator.free(output);

    const expected =
        "<div>\n" ++
        "  <br/>\n" ++
        "  <hr/>\n" ++
        "</div>\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "htmlfmt void elements" {
    const output = try execWithInput("<div><img src=\"a.png\"><input type=\"text\"></div>", null);
    defer std.testing.allocator.free(output);

    const expected =
        "<div>\n" ++
        "  <img src=\"a.png\">\n" ++
        "  <input type=\"text\">\n" ++
        "</div>\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "htmlfmt doctype and html" {
    const output = try execWithInput("<!DOCTYPE html><html><head><title>Test</title></head><body><p>hi</p></body></html>", null);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.startsWith(u8, output, "<!DOCTYPE html>\n"));
    try std.testing.expect(std.mem.indexOf(u8, output, "<html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  <head>") != null);
}

test "htmlfmt comment" {
    const output = try execWithInput("<div><!-- comment --><p>hi</p></div>", null);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "<!-- comment -->") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<p>hi</p>") != null);
}

test "htmlfmt unknown subcommand" {
    const result = execWithInput("<div></div>", "foo");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "htmlfmt command struct" {
    try std.testing.expectEqualStrings("htmlfmt", command.name);
    try std.testing.expectEqual(registry.Category.docs, command.category);
}
