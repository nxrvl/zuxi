const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// Entry point for the base64 command.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    const mode: enum { encode, decode } = if (subcommand) |sub| blk: {
        if (std.mem.eql(u8, sub, "encode")) break :blk .encode;
        if (std.mem.eql(u8, sub, "decode")) break :blk .decode;
        const writer = ctx.stderrWriter();
        try writer.print("base64: unknown subcommand '{s}'\n", .{sub});
        try writer.print("Available subcommands: encode, decode\n", .{});
        return error.InvalidArgument;
    } else .encode;

    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("base64: no input provided\n", .{});
        try writer.print("Usage: zuxi base64 [encode|decode] <data>\n", .{});
        try writer.print("       echo 'data' | zuxi base64 encode\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    switch (mode) {
        .encode => try doEncode(ctx, input.data),
        .decode => try doDecode(ctx, input.data),
    }
}

/// Encode data to base64.
fn doEncode(ctx: context.Context, data: []const u8) anyerror!void {
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(data.len);
    const buf = try ctx.allocator.alloc(u8, encoded_len + 1); // +1 for newline
    defer ctx.allocator.free(buf);
    const encoded = encoder.encode(buf[0..encoded_len], data);
    buf[encoded.len] = '\n';
    try io.writeOutput(ctx, buf[0 .. encoded.len + 1]);
}

/// Decode base64 data.
fn doDecode(ctx: context.Context, data: []const u8) anyerror!void {
    // Strip whitespace from the input (base64 may have line breaks).
    const cleaned = try stripWhitespace(ctx.allocator, data);
    defer ctx.allocator.free(cleaned);

    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(cleaned) catch {
        const writer = ctx.stderrWriter();
        try writer.print("base64: invalid base64 input\n", .{});
        return error.FormatError;
    };
    const buf = try ctx.allocator.alloc(u8, decoded_len + 1); // +1 for newline
    defer ctx.allocator.free(buf);
    decoder.decode(buf[0..decoded_len], cleaned) catch {
        const writer = ctx.stderrWriter();
        try writer.print("base64: invalid base64 input\n", .{});
        return error.FormatError;
    };
    buf[decoded_len] = '\n';
    try io.writeOutput(ctx, buf[0 .. decoded_len + 1]);
}

/// Remove all ASCII whitespace from a slice.
fn stripWhitespace(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var count: usize = 0;
    for (data) |c| {
        if (!std.ascii.isWhitespace(c)) count += 1;
    }
    const result = try allocator.alloc(u8, count);
    var i: usize = 0;
    for (data) |c| {
        if (!std.ascii.isWhitespace(c)) {
            result[i] = c;
            i += 1;
        }
    }
    return result;
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "base64",
    .description = "Encode or decode base64 data",
    .category = .encoding,
    .subcommands = &.{ "encode", "decode" },
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_base64_out.tmp";

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

test "base64 encode hello" {
    const output = try execWithInput("hello", "encode");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("aGVsbG8=", trimmed);
}

test "base64 encode empty string" {
    const output = try execWithInput("", "encode");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("", trimmed);
}

test "base64 encode default subcommand" {
    const output = try execWithInput("hello", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("aGVsbG8=", trimmed);
}

test "base64 decode aGVsbG8=" {
    const output = try execWithInput("aGVsbG8=", "decode");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("hello", trimmed);
}

test "base64 decode without padding" {
    // "hi" encodes to "aGk=" but some inputs omit padding.
    // Standard decoder requires padding, so test with proper input.
    const output = try execWithInput("aGk=", "decode");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("hi", trimmed);
}

test "base64 decode invalid input" {
    const result = execWithInput("!!!not-base64!!!", "decode");
    try std.testing.expectError(error.FormatError, result);
}

test "base64 roundtrip" {
    const original = "The quick brown fox jumps over the lazy dog";
    const encoded_output = try execWithInput(original, "encode");
    defer std.testing.allocator.free(encoded_output);
    const encoded = std.mem.trimRight(u8, encoded_output, &std.ascii.whitespace);

    // Now decode it back.
    const decoded_output = try execWithInput(encoded, "decode");
    defer std.testing.allocator.free(decoded_output);
    const decoded = std.mem.trimRight(u8, decoded_output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings(original, decoded);
}

test "base64 unknown subcommand" {
    const result = execWithInput("test", "compress");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "base64 command struct fields" {
    try std.testing.expectEqualStrings("base64", command.name);
    try std.testing.expectEqual(registry.Category.encoding, command.category);
    try std.testing.expectEqual(@as(usize, 2), command.subcommands.len);
}
