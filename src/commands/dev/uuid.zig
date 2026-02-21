const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// Entry point for the uuid command.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    const sub = subcommand orelse "generate";

    if (std.mem.eql(u8, sub, "generate")) {
        try generateUuid(ctx);
    } else if (std.mem.eql(u8, sub, "decode")) {
        try decodeUuid(ctx);
    } else {
        const writer = ctx.stderrWriter();
        try writer.print("uuid: unknown subcommand '{s}'\n", .{sub});
        try writer.print("Available subcommands: generate, decode\n", .{});
        return error.InvalidArgument;
    }
}

/// Generate a random UUID v4.
fn generateUuid(ctx: context.Context) anyerror!void {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    // Set version to 4 (random)
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    // Set variant to RFC 4122 (10xx)
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    var out_buf: [36]u8 = undefined;
    const uuid_str = formatUuid(bytes, &out_buf);

    var result_buf: [37]u8 = undefined;
    @memcpy(result_buf[0..36], uuid_str);
    result_buf[36] = '\n';
    try io.writeOutput(ctx, result_buf[0..37]);
}

/// Decode a UUID and show its metadata.
fn decodeUuid(ctx: context.Context) anyerror!void {
    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("uuid: no input provided\n", .{});
        try writer.print("Usage: zuxi uuid decode <uuid-string>\n", .{});
        try writer.print("       echo '550e8400-e29b-41d4-a716-446655440000' | zuxi uuid decode\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    if (input.data.len == 0) {
        const writer = ctx.stderrWriter();
        try writer.print("uuid: no input provided\n", .{});
        return error.MissingArgument;
    }

    const bytes = parseUuid(input.data) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("uuid: invalid UUID format: '{s}'\n", .{input.data});
        try writer.print("Expected format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\n", .{});
        return error.InvalidInput;
    };

    const version = (bytes[6] >> 4) & 0x0F;
    const variant_bits: u2 = @truncate((bytes[8] >> 6) & 0x03);

    const variant_str = switch (variant_bits) {
        0b00 => "NCS (reserved)",
        0b01 => "NCS (reserved)",
        0b10 => "RFC 4122",
        0b11 => "Microsoft (reserved)",
    };

    const version_str = switch (version) {
        1 => "Time-based (v1)",
        2 => "DCE Security (v2)",
        3 => "Name-based MD5 (v3)",
        4 => "Random (v4)",
        5 => "Name-based SHA-1 (v5)",
        6 => "Sortable time-based (v6)",
        7 => "Unix epoch time-based (v7)",
        else => "Unknown",
    };

    var out_buf: [512]u8 = undefined;
    var pos: usize = 0;

    // Format UUID string for display
    var uuid_display: [36]u8 = undefined;
    const uuid_str = formatUuid(bytes, &uuid_display);

    pos += (std.fmt.bufPrint(out_buf[pos..], "UUID:    {s}\n", .{uuid_str}) catch return error.BufferTooSmall).len;
    pos += (std.fmt.bufPrint(out_buf[pos..], "Version: {d} ({s})\n", .{ version, version_str }) catch return error.BufferTooSmall).len;
    pos += (std.fmt.bufPrint(out_buf[pos..], "Variant: {s}\n", .{variant_str}) catch return error.BufferTooSmall).len;

    // For v1 UUIDs, extract and show the timestamp
    if (version == 1) {
        const timestamp = extractV1Timestamp(bytes);
        if (timestamp) |ts| {
            // Convert 100-nanosecond intervals since UUID epoch (Oct 15, 1582) to Unix seconds
            const uuid_epoch_offset: i64 = 12219292800; // seconds between UUID epoch and Unix epoch
            const unix_seconds = @divFloor(ts, 10_000_000) - uuid_epoch_offset;
            pos += (std.fmt.bufPrint(out_buf[pos..], "Time:    Unix timestamp {d}\n", .{unix_seconds}) catch return error.BufferTooSmall).len;
        }
    }

    try io.writeOutput(ctx, out_buf[0..pos]);
}

/// Format 16 bytes as a UUID string (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx).
pub fn formatUuid(bytes: [16]u8, buf: *[36]u8) []const u8 {
    const hex_chars = "0123456789abcdef";
    var pos: usize = 0;
    const groups = [_]struct { start: usize, len: usize }{
        .{ .start = 0, .len = 4 },
        .{ .start = 4, .len = 2 },
        .{ .start = 6, .len = 2 },
        .{ .start = 8, .len = 2 },
        .{ .start = 10, .len = 6 },
    };

    for (groups, 0..) |group, gi| {
        if (gi > 0) {
            buf[pos] = '-';
            pos += 1;
        }
        for (0..group.len) |i| {
            const byte = bytes[group.start + i];
            buf[pos] = hex_chars[byte >> 4];
            buf[pos + 1] = hex_chars[byte & 0x0F];
            pos += 2;
        }
    }

    return buf[0..36];
}

/// Parse a UUID string into 16 bytes. Returns null if the format is invalid.
pub fn parseUuid(input: []const u8) ?[16]u8 {
    if (input.len != 36) return null;

    // Validate dashes at expected positions
    if (input[8] != '-' or input[13] != '-' or input[18] != '-' or input[23] != '-') return null;

    var bytes: [16]u8 = undefined;
    var byte_idx: usize = 0;

    var i: usize = 0;
    while (i < 36) {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            i += 1;
            continue;
        }
        if (i + 1 >= 36) return null;
        const hi = hexVal(input[i]) orelse return null;
        const lo = hexVal(input[i + 1]) orelse return null;
        if (byte_idx >= 16) return null;
        bytes[byte_idx] = (hi << 4) | lo;
        byte_idx += 1;
        i += 2;
    }

    if (byte_idx != 16) return null;
    return bytes;
}

/// Convert a hex character to its numeric value.
fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

/// Extract the 60-bit timestamp from a v1 UUID.
fn extractV1Timestamp(bytes: [16]u8) ?i64 {
    // time_low (bytes 0-3), time_mid (bytes 4-5), time_hi (bytes 6-7, lower 12 bits)
    const time_low: u64 = @as(u64, bytes[0]) << 24 | @as(u64, bytes[1]) << 16 | @as(u64, bytes[2]) << 8 | @as(u64, bytes[3]);
    const time_mid: u64 = @as(u64, bytes[4]) << 8 | @as(u64, bytes[5]);
    const time_hi: u64 = @as(u64, bytes[6] & 0x0F) << 8 | @as(u64, bytes[7]);

    const timestamp: u64 = (time_hi << 48) | (time_mid << 32) | time_low;
    return @intCast(timestamp);
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "uuid",
    .description = "Generate and decode UUIDs",
    .category = .dev,
    .subcommands = &.{ "generate", "decode" },
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: ?[]const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_uuid_out.tmp";
    const tmp_in = "zuxi_test_uuid_in.tmp";
    const out_file = try std.fs.cwd().createFile(tmp_out, .{});

    // Create an empty stdin file so getInput won't block on real stdin.
    const empty_in = try std.fs.cwd().createFile(tmp_in, .{});
    empty_in.close();
    const stdin_file = try std.fs.cwd().openFile(tmp_in, .{});

    var args_buf: [1][]const u8 = undefined;
    var args_slice: []const []const u8 = &.{};
    if (input) |inp| {
        args_buf[0] = inp;
        args_slice = args_buf[0..1];
    }

    var ctx = context.Context.initDefault(allocator);
    ctx.args = args_slice;
    ctx.stdout = out_file;
    ctx.stdin = stdin_file;

    execute(ctx, subcommand) catch |err| {
        out_file.close();
        stdin_file.close();
        std.fs.cwd().deleteFile(tmp_out) catch {};
        std.fs.cwd().deleteFile(tmp_in) catch {};
        return err;
    };
    out_file.close();
    stdin_file.close();
    std.fs.cwd().deleteFile(tmp_in) catch {};

    const file = try std.fs.cwd().openFile(tmp_out, .{});
    defer file.close();
    defer std.fs.cwd().deleteFile(tmp_out) catch {};
    return try file.readToEndAlloc(allocator, io.max_input_size);
}

test "uuid generate produces valid format" {
    const output = try execWithInput(null, "generate");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);

    // Must be 36 chars: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    try std.testing.expectEqual(@as(usize, 36), trimmed.len);
    try std.testing.expectEqual(@as(u8, '-'), trimmed[8]);
    try std.testing.expectEqual(@as(u8, '-'), trimmed[13]);
    try std.testing.expectEqual(@as(u8, '-'), trimmed[18]);
    try std.testing.expectEqual(@as(u8, '-'), trimmed[23]);
}

test "uuid generate is version 4" {
    const output = try execWithInput(null, "generate");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);

    // Version nibble (position 14) must be '4'
    try std.testing.expectEqual(@as(u8, '4'), trimmed[14]);

    // Variant nibble (position 19) must be 8, 9, a, or b
    const variant_char = trimmed[19];
    try std.testing.expect(variant_char == '8' or variant_char == '9' or
        variant_char == 'a' or variant_char == 'b');
}

test "uuid generate produces unique values" {
    const output1 = try execWithInput(null, "generate");
    defer std.testing.allocator.free(output1);
    const output2 = try execWithInput(null, "generate");
    defer std.testing.allocator.free(output2);

    const trimmed1 = std.mem.trimRight(u8, output1, &std.ascii.whitespace);
    const trimmed2 = std.mem.trimRight(u8, output2, &std.ascii.whitespace);
    try std.testing.expect(!std.mem.eql(u8, trimmed1, trimmed2));
}

test "uuid decode v4" {
    const output = try execWithInput("550e8400-e29b-41d4-a716-446655440000", "decode");
    defer std.testing.allocator.free(output);

    // Should contain version 4 info
    try std.testing.expect(std.mem.indexOf(u8, output, "Version: 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Random (v4)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "RFC 4122") != null);
}

test "uuid decode v1" {
    // A known v1 UUID
    const output = try execWithInput("6ba7b810-9dad-11d1-80b4-00c04fd430c8", "decode");
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "Version: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Time-based (v1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Time:") != null);
}

test "uuid decode invalid format" {
    const result = execWithInput("not-a-uuid", "decode");
    try std.testing.expectError(error.InvalidInput, result);
}

test "uuid decode no input" {
    const result = execWithInput(null, "decode");
    try std.testing.expectError(error.MissingArgument, result);
}

test "uuid unknown subcommand" {
    const result = execWithInput(null, "invalid");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "uuid command struct fields" {
    try std.testing.expectEqualStrings("uuid", command.name);
    try std.testing.expectEqual(registry.Category.dev, command.category);
    try std.testing.expectEqual(@as(usize, 2), command.subcommands.len);
}

test "parseUuid valid" {
    const bytes = parseUuid("550e8400-e29b-41d4-a716-446655440000");
    try std.testing.expect(bytes != null);
    const b = bytes.?;
    try std.testing.expectEqual(@as(u8, 0x55), b[0]);
    try std.testing.expectEqual(@as(u8, 0x0e), b[1]);
}

test "parseUuid invalid length" {
    try std.testing.expect(parseUuid("too-short") == null);
    try std.testing.expect(parseUuid("") == null);
}

test "parseUuid invalid characters" {
    try std.testing.expect(parseUuid("gggggggg-gggg-gggg-gggg-gggggggggggg") == null);
}

test "formatUuid roundtrip" {
    const original = "550e8400-e29b-41d4-a716-446655440000";
    const bytes = parseUuid(original).?;
    var buf: [36]u8 = undefined;
    const formatted = formatUuid(bytes, &buf);
    try std.testing.expectEqualStrings(original, formatted);
}
