const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// Entry point for the urlencode command.
/// URL percent-encoding per RFC 3986.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    const mode: enum { encode, decode } = if (subcommand) |sub| blk: {
        if (std.mem.eql(u8, sub, "encode")) break :blk .encode;
        if (std.mem.eql(u8, sub, "decode")) break :blk .decode;
        const writer = ctx.stderrWriter();
        try writer.print("urlencode: unknown subcommand '{s}'\n", .{sub});
        try writer.print("Available subcommands: encode, decode\n", .{});
        return error.InvalidArgument;
    } else .encode;

    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("urlencode: no input provided\n", .{});
        try writer.print("Usage: zuxi urlencode [encode|decode] <text>\n", .{});
        try writer.print("       echo 'text' | zuxi urlencode encode\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    switch (mode) {
        .encode => try doEncode(ctx, input.data),
        .decode => try doDecode(ctx, input.data),
    }
}

/// RFC 3986 unreserved characters: ALPHA, DIGIT, '-', '.', '_', '~'
fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

const hex_chars = "0123456789ABCDEF";

/// Percent-encode a string per RFC 3986.
fn doEncode(ctx: context.Context, data: []const u8) anyerror!void {
    var list = std.ArrayList(u8){};
    defer list.deinit(ctx.allocator);

    for (data) |c| {
        if (isUnreserved(c)) {
            try list.append(ctx.allocator, c);
        } else {
            try list.append(ctx.allocator, '%');
            try list.append(ctx.allocator, hex_chars[c >> 4]);
            try list.append(ctx.allocator, hex_chars[c & 0x0F]);
        }
    }
    try list.append(ctx.allocator, '\n');
    try io.writeOutput(ctx, list.items);
}

/// Decode a percent-encoded string.
fn doDecode(ctx: context.Context, data: []const u8) anyerror!void {
    var list = std.ArrayList(u8){};
    defer list.deinit(ctx.allocator);

    var i: usize = 0;
    while (i < data.len) {
        if (data[i] == '%' and i + 2 < data.len) {
            const high = hexVal(data[i + 1]) orelse {
                const writer = ctx.stderrWriter();
                try writer.print("urlencode: invalid percent-encoding at position {d}\n", .{i});
                return error.FormatError;
            };
            const low = hexVal(data[i + 2]) orelse {
                const writer = ctx.stderrWriter();
                try writer.print("urlencode: invalid percent-encoding at position {d}\n", .{i});
                return error.FormatError;
            };
            try list.append(ctx.allocator, (high << 4) | low);
            i += 3;
        } else if (data[i] == '+') {
            // Also decode '+' as space (common in query strings).
            try list.append(ctx.allocator, ' ');
            i += 1;
        } else {
            try list.append(ctx.allocator, data[i]);
            i += 1;
        }
    }
    try list.append(ctx.allocator, '\n');
    try io.writeOutput(ctx, list.items);
}

/// Convert a hex character to its numeric value.
fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    return null;
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "urlencode",
    .description = "URL percent-encoding and decoding (RFC 3986)",
    .category = .encoding,
    .subcommands = &.{ "encode", "decode" },
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_urlencode_out.tmp";

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

test "urlencode encode simple text" {
    const output = try execWithInput("hello world", "encode");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("hello%20world", trimmed);
}

test "urlencode encode default subcommand" {
    const output = try execWithInput("hello world", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("hello%20world", trimmed);
}

test "urlencode encode special characters" {
    const output = try execWithInput("foo=bar&baz=qux", "encode");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("foo%3Dbar%26baz%3Dqux", trimmed);
}

test "urlencode encode preserves unreserved" {
    const output = try execWithInput("hello-world_test.txt~", "encode");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("hello-world_test.txt~", trimmed);
}

test "urlencode encode unicode" {
    // UTF-8 bytes of "ü" are 0xC3, 0xBC
    const output = try execWithInput("über", "encode");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("%C3%BCber", trimmed);
}

test "urlencode decode simple" {
    const output = try execWithInput("hello%20world", "decode");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("hello world", trimmed);
}

test "urlencode decode plus as space" {
    const output = try execWithInput("hello+world", "decode");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("hello world", trimmed);
}

test "urlencode decode special characters" {
    const output = try execWithInput("foo%3Dbar%26baz%3Dqux", "decode");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("foo=bar&baz=qux", trimmed);
}

test "urlencode decode lowercase hex" {
    const output = try execWithInput("hello%2fworld", "decode");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("hello/world", trimmed);
}

test "urlencode roundtrip" {
    const original = "Hello, World! @#$%^&*()";
    const encoded_output = try execWithInput(original, "encode");
    defer std.testing.allocator.free(encoded_output);
    const encoded = std.mem.trimRight(u8, encoded_output, &std.ascii.whitespace);

    const decoded_output = try execWithInput(encoded, "decode");
    defer std.testing.allocator.free(decoded_output);
    const decoded = std.mem.trimRight(u8, decoded_output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings(original, decoded);
}

test "urlencode encode empty string" {
    const output = try execWithInput("", "encode");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("", trimmed);
}

test "urlencode decode empty string" {
    const output = try execWithInput("", "decode");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("", trimmed);
}

test "urlencode unknown subcommand" {
    const result = execWithInput("test", "compress");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "urlencode command struct fields" {
    try std.testing.expectEqualStrings("urlencode", command.name);
    try std.testing.expectEqual(registry.Category.encoding, command.category);
    try std.testing.expectEqual(@as(usize, 2), command.subcommands.len);
}
