const std = @import("std");
const context = @import("context.zig");
const io_mod = @import("io.zig");

// --- ANSI escape code constants ---

pub const red = "\x1b[31m";
pub const green = "\x1b[32m";
pub const yellow = "\x1b[33m";
pub const blue = "\x1b[34m";
pub const magenta = "\x1b[35m";
pub const cyan = "\x1b[36m";
pub const white = "\x1b[37m";
pub const gray = "\x1b[90m";
pub const bold = "\x1b[1m";
pub const dim = "\x1b[2m";
pub const reset = "\x1b[0m";

/// Write text wrapped in an ANSI color code, respecting no_color setting.
/// When no_color is true, writes text without escape codes.
pub fn colorize(writer: anytype, text: []const u8, color_code: []const u8, no_color: bool) !void {
    if (no_color) {
        try writer.writeAll(text);
    } else {
        try writer.writeAll(color_code);
        try writer.writeAll(text);
        try writer.writeAll(reset);
    }
}

/// Determine whether colored output should be used based on context.
/// Returns false if --no-color flag is set, output goes to a file, or stdout is not a TTY.
pub fn shouldColor(ctx: context.Context) bool {
    if (ctx.flags.no_color) return false;
    if (ctx.flags.output_file != null) return false;
    return io_mod.isTty(ctx.stdout);
}

/// Write JSON with syntax highlighting.
/// Keys = cyan, strings = green, numbers = yellow, booleans = magenta,
/// null = gray, braces/brackets/colons/commas = white.
pub fn writeColoredJson(writer: anytype, json_str: []const u8, no_color: bool) !void {
    if (no_color) {
        try writer.writeAll(json_str);
        return;
    }

    var i: usize = 0;
    while (i < json_str.len) {
        const c = json_str[i];
        switch (c) {
            '"' => {
                // Determine if this is a key or a value by scanning context.
                const is_key = isJsonKey(json_str, i);
                const str_end = findStringEnd(json_str, i);
                const str_slice = json_str[i..str_end];
                const color_code = if (is_key) cyan else green;
                try writer.writeAll(color_code);
                try writer.writeAll(str_slice);
                try writer.writeAll(reset);
                i = str_end;
            },
            '-', '0'...'9' => {
                const num_end = findNumberEnd(json_str, i);
                try writer.writeAll(yellow);
                try writer.writeAll(json_str[i..num_end]);
                try writer.writeAll(reset);
                i = num_end;
            },
            't' => {
                if (i + 4 <= json_str.len and std.mem.eql(u8, json_str[i..][0..4], "true")) {
                    try writer.writeAll(magenta);
                    try writer.writeAll("true");
                    try writer.writeAll(reset);
                    i += 4;
                } else {
                    try writer.writeByte(c);
                    i += 1;
                }
            },
            'f' => {
                if (i + 5 <= json_str.len and std.mem.eql(u8, json_str[i..][0..5], "false")) {
                    try writer.writeAll(magenta);
                    try writer.writeAll("false");
                    try writer.writeAll(reset);
                    i += 5;
                } else {
                    try writer.writeByte(c);
                    i += 1;
                }
            },
            'n' => {
                if (i + 4 <= json_str.len and std.mem.eql(u8, json_str[i..][0..4], "null")) {
                    try writer.writeAll(gray);
                    try writer.writeAll("null");
                    try writer.writeAll(reset);
                    i += 4;
                } else {
                    try writer.writeByte(c);
                    i += 1;
                }
            },
            '{', '}', '[', ']', ':', ',' => {
                try writer.writeAll(white);
                try writer.writeByte(c);
                try writer.writeAll(reset);
                i += 1;
            },
            else => {
                // Whitespace and anything else passes through uncolored.
                try writer.writeByte(c);
                i += 1;
            },
        }
    }
}

/// Check if the string starting at pos is a JSON key (followed by ':' after optional whitespace).
fn isJsonKey(json: []const u8, pos: usize) bool {
    const str_end = findStringEnd(json, pos);
    var j = str_end;
    while (j < json.len and (json[j] == ' ' or json[j] == '\t' or json[j] == '\n' or json[j] == '\r')) {
        j += 1;
    }
    return j < json.len and json[j] == ':';
}

/// Find the end of a JSON string starting at pos (pos points to opening '"').
/// Returns index one past the closing '"'.
fn findStringEnd(json: []const u8, pos: usize) usize {
    var i = pos + 1; // Skip opening quote.
    while (i < json.len) {
        if (json[i] == '\\') {
            i += 2; // Skip escaped character.
            continue;
        }
        if (json[i] == '"') {
            return i + 1; // One past closing quote.
        }
        i += 1;
    }
    return json.len; // Unterminated string, return end.
}

/// Find the end of a JSON number starting at pos.
fn findNumberEnd(json: []const u8, pos: usize) usize {
    var i = pos;
    while (i < json.len) {
        switch (json[i]) {
            '-', '+', '0'...'9', '.', 'e', 'E' => i += 1,
            else => break,
        }
    }
    return i;
}

// --- Tests ---

test "colorize with color enabled" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    try colorize(writer, "hello", red, false);
    const output = stream.getWritten();
    try std.testing.expectEqualStrings("\x1b[31mhello\x1b[0m", output);
}

test "colorize with color disabled" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    try colorize(writer, "hello", red, true);
    const output = stream.getWritten();
    try std.testing.expectEqualStrings("hello", output);
}

test "colorize with bold" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    try colorize(writer, "title", bold, false);
    const output = stream.getWritten();
    try std.testing.expectEqualStrings("\x1b[1mtitle\x1b[0m", output);
}

test "colorize empty string" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    try colorize(writer, "", green, false);
    const output = stream.getWritten();
    try std.testing.expectEqualStrings("\x1b[32m\x1b[0m", output);
}

test "shouldColor returns false when no_color is set" {
    var ctx = context.Context.initDefault(std.testing.allocator);
    ctx.flags.no_color = true;
    try std.testing.expect(!shouldColor(ctx));
}

test "shouldColor returns false when output_file is set" {
    var ctx = context.Context.initDefault(std.testing.allocator);
    ctx.flags.output_file = "output.txt";
    try std.testing.expect(!shouldColor(ctx));
}

test "shouldColor returns false for non-TTY stdout" {
    // Create a temp file (not a TTY) and use it as stdout.
    const tmp_path = "zuxi_test_color_tty.tmp";
    const f = try std.fs.cwd().createFile(tmp_path, .{});
    defer f.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var ctx = context.Context.initDefault(std.testing.allocator);
    ctx.stdout = f;
    ctx.flags.no_color = false;
    try std.testing.expect(!shouldColor(ctx));
}

test "writeColoredJson with no_color passes through" {
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    const json = "{\"key\": \"value\"}";
    try writeColoredJson(writer, json, true);
    const output = stream.getWritten();
    try std.testing.expectEqualStrings(json, output);
}

test "writeColoredJson highlights keys in cyan" {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    try writeColoredJson(writer, "{\"name\": \"zuxi\"}", false);
    const output = stream.getWritten();
    // Key "name" should be wrapped in cyan
    try std.testing.expect(std.mem.indexOf(u8, output, cyan ++ "\"name\"" ++ reset) != null);
    // Value "zuxi" should be wrapped in green
    try std.testing.expect(std.mem.indexOf(u8, output, green ++ "\"zuxi\"" ++ reset) != null);
}

test "writeColoredJson highlights numbers in yellow" {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    try writeColoredJson(writer, "{\"count\": 42}", false);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, yellow ++ "42" ++ reset) != null);
}

test "writeColoredJson highlights booleans in magenta" {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    try writeColoredJson(writer, "{\"ok\": true, \"fail\": false}", false);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, magenta ++ "true" ++ reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, magenta ++ "false" ++ reset) != null);
}

test "writeColoredJson highlights null in gray" {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    try writeColoredJson(writer, "{\"val\": null}", false);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, gray ++ "null" ++ reset) != null);
}

test "writeColoredJson highlights braces and brackets" {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    try writeColoredJson(writer, "{\"a\": [1]}", false);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, white ++ "{" ++ reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, white ++ "}" ++ reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, white ++ "[" ++ reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, white ++ "]" ++ reset) != null);
}

test "writeColoredJson handles escaped quotes in strings" {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    const json = "{\"msg\": \"say \\\"hi\\\"\"}";
    try writeColoredJson(writer, json, false);
    const output = stream.getWritten();
    // The whole string including escapes should be in green
    try std.testing.expect(std.mem.indexOf(u8, output, green ++ "\"say \\\"hi\\\"\"" ++ reset) != null);
}

test "writeColoredJson handles negative numbers" {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    try writeColoredJson(writer, "{\"temp\": -10.5}", false);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, yellow ++ "-10.5" ++ reset) != null);
}

test "writeColoredJson empty object" {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    try writeColoredJson(writer, "{}", false);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, white ++ "{" ++ reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, white ++ "}" ++ reset) != null);
}

test "findStringEnd handles basic string" {
    const json = "\"hello\" rest";
    const end = findStringEnd(json, 0);
    try std.testing.expectEqual(@as(usize, 7), end);
}

test "findStringEnd handles escaped quotes" {
    const json = "\"say \\\"hi\\\"\" rest";
    const end = findStringEnd(json, 0);
    try std.testing.expectEqualStrings("\"say \\\"hi\\\"\"", json[0..end]);
}

test "findNumberEnd handles integer" {
    const end = findNumberEnd("42,", 0);
    try std.testing.expectEqual(@as(usize, 2), end);
}

test "findNumberEnd handles negative float" {
    const end = findNumberEnd("-3.14}", 0);
    try std.testing.expectEqual(@as(usize, 5), end);
}

test "findNumberEnd handles scientific notation" {
    const end = findNumberEnd("1.5e10 ", 0);
    try std.testing.expectEqual(@as(usize, 6), end);
}

test "isJsonKey identifies key" {
    const json = "\"name\": \"value\"";
    try std.testing.expect(isJsonKey(json, 0));
}

test "isJsonKey identifies value" {
    const json = "\"name\": \"value\"";
    // "value" starts at index 8
    try std.testing.expect(!isJsonKey(json, 8));
}

test "color constants are valid ANSI codes" {
    // All color codes should start with ESC[ and not be empty.
    const codes = [_][]const u8{ red, green, yellow, blue, magenta, cyan, white, gray, bold, dim, reset };
    for (codes) |code| {
        try std.testing.expect(code.len > 0);
        try std.testing.expect(code[0] == 0x1b);
        try std.testing.expect(code[1] == '[');
    }
}
