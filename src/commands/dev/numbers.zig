const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

const Base = enum { bin, oct, dec, hex };

/// Entry point for the numbers command.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    const target: ?Base = if (subcommand) |sub| blk: {
        if (std.mem.eql(u8, sub, "bin")) break :blk .bin;
        if (std.mem.eql(u8, sub, "oct")) break :blk .oct;
        if (std.mem.eql(u8, sub, "dec")) break :blk .dec;
        if (std.mem.eql(u8, sub, "hex")) break :blk .hex;
        if (std.mem.eql(u8, sub, "all")) break :blk null;
        const writer = ctx.stderrWriter();
        try writer.print("numbers: unknown subcommand '{s}'\n", .{sub});
        try writer.print("Available subcommands: bin, oct, dec, hex, all\n", .{});
        return error.InvalidArgument;
    } else null; // default = all

    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("numbers: no input provided\n", .{});
        try writer.print("Usage: zuxi numbers [bin|oct|dec|hex|all] <number>\n", .{});
        try writer.print("       echo '255' | zuxi numbers hex\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    const value = parseNumber(input.data) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("numbers: invalid number '{s}'\n", .{input.data});
        return error.InvalidInput;
    };

    if (target) |base| {
        var buf: [130]u8 = undefined;
        const formatted = formatBase(value, base, &buf);
        var out_buf: [131]u8 = undefined;
        @memcpy(out_buf[0..formatted.len], formatted);
        out_buf[formatted.len] = '\n';
        try io.writeOutput(ctx, out_buf[0 .. formatted.len + 1]);
    } else {
        // Show all bases.
        try writeAllBases(ctx, value);
    }
}

/// Parse a number string, auto-detecting base from prefix.
/// Supports: 0x (hex), 0b (binary), 0o (octal), or plain decimal.
fn parseNumber(input: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;

    if (trimmed.len > 2) {
        if (std.mem.startsWith(u8, trimmed, "0x") or std.mem.startsWith(u8, trimmed, "0X")) {
            return std.fmt.parseInt(u64, trimmed[2..], 16) catch null;
        }
        if (std.mem.startsWith(u8, trimmed, "0b") or std.mem.startsWith(u8, trimmed, "0B")) {
            return std.fmt.parseInt(u64, trimmed[2..], 2) catch null;
        }
        if (std.mem.startsWith(u8, trimmed, "0o") or std.mem.startsWith(u8, trimmed, "0O")) {
            return std.fmt.parseInt(u64, trimmed[2..], 8) catch null;
        }
    }

    // Default: decimal.
    return std.fmt.parseInt(u64, trimmed, 10) catch null;
}

/// Format a value in the given base into the provided buffer. Returns the slice.
fn formatBase(value: u64, base: Base, buf: *[130]u8) []const u8 {
    switch (base) {
        .bin => {
            if (value == 0) {
                buf[0] = '0';
                buf[1] = 'b';
                buf[2] = '0';
                return buf[0..3];
            }
            // Write "0b" prefix then binary digits.
            buf[0] = '0';
            buf[1] = 'b';
            var pos: usize = 2;
            // Find highest set bit.
            var v = value;
            var bits: u7 = 0;
            while (v > 0) : (v >>= 1) {
                bits += 1;
            }
            // Write bits from MSB to LSB.
            var i: u7 = bits;
            while (i > 0) {
                i -= 1;
                const bit_val: u64 = @as(u64, 1) << @as(u6, @intCast(i));
                buf[pos] = if (value & bit_val != 0) '1' else '0';
                pos += 1;
            }
            return buf[0..pos];
        },
        .oct => {
            if (value == 0) {
                buf[0] = '0';
                buf[1] = 'o';
                buf[2] = '0';
                return buf[0..3];
            }
            buf[0] = '0';
            buf[1] = 'o';
            // Format octal digits.
            var tmp: [22]u8 = undefined;
            var pos: usize = tmp.len;
            var v = value;
            while (v > 0) {
                pos -= 1;
                tmp[pos] = @intCast((v % 8) + '0');
                v /= 8;
            }
            const digits = tmp[pos..];
            @memcpy(buf[2 .. 2 + digits.len], digits);
            return buf[0 .. 2 + digits.len];
        },
        .dec => {
            // Format decimal.
            var tmp: [20]u8 = undefined;
            var pos: usize = tmp.len;
            var v = value;
            if (v == 0) {
                buf[0] = '0';
                return buf[0..1];
            }
            while (v > 0) {
                pos -= 1;
                tmp[pos] = @intCast((v % 10) + '0');
                v /= 10;
            }
            const digits = tmp[pos..];
            @memcpy(buf[0..digits.len], digits);
            return buf[0..digits.len];
        },
        .hex => {
            if (value == 0) {
                buf[0] = '0';
                buf[1] = 'x';
                buf[2] = '0';
                return buf[0..3];
            }
            buf[0] = '0';
            buf[1] = 'x';
            const hex_chars = "0123456789abcdef";
            var tmp: [16]u8 = undefined;
            var pos: usize = tmp.len;
            var v = value;
            while (v > 0) {
                pos -= 1;
                tmp[pos] = hex_chars[@intCast(v & 0xf)];
                v >>= 4;
            }
            const digits = tmp[pos..];
            @memcpy(buf[2 .. 2 + digits.len], digits);
            return buf[0 .. 2 + digits.len];
        },
    }
}

/// Write all base representations with labels.
fn writeAllBases(ctx: context.Context, value: u64) !void {
    var buf: [130]u8 = undefined;
    var out: [600]u8 = undefined;
    var pos: usize = 0;

    const bases = [_]struct { label: []const u8, base: Base }{
        .{ .label = "bin: ", .base = .bin },
        .{ .label = "oct: ", .base = .oct },
        .{ .label = "dec: ", .base = .dec },
        .{ .label = "hex: ", .base = .hex },
    };

    for (bases) |entry| {
        @memcpy(out[pos .. pos + entry.label.len], entry.label);
        pos += entry.label.len;
        const formatted = formatBase(value, entry.base, &buf);
        @memcpy(out[pos .. pos + formatted.len], formatted);
        pos += formatted.len;
        out[pos] = '\n';
        pos += 1;
    }

    try io.writeOutput(ctx, out[0..pos]);
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "numbers",
    .description = "Convert between binary, octal, decimal, and hex",
    .category = .dev,
    .subcommands = &.{ "bin", "oct", "dec", "hex", "all" },
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_numbers_out.tmp";

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

test "numbers decimal to hex" {
    const output = try execWithInput("255", "hex");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("0xff", trimmed);
}

test "numbers decimal to binary" {
    const output = try execWithInput("10", "bin");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("0b1010", trimmed);
}

test "numbers decimal to octal" {
    const output = try execWithInput("8", "oct");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("0o10", trimmed);
}

test "numbers decimal to decimal" {
    const output = try execWithInput("42", "dec");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("42", trimmed);
}

test "numbers hex input auto-detect" {
    const output = try execWithInput("0xff", "dec");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("255", trimmed);
}

test "numbers binary input auto-detect" {
    const output = try execWithInput("0b1010", "dec");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("10", trimmed);
}

test "numbers octal input auto-detect" {
    const output = try execWithInput("0o17", "dec");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("15", trimmed);
}

test "numbers zero all bases" {
    const output = try execWithInput("0", null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "bin: 0b0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "oct: 0o0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "dec: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hex: 0x0") != null);
}

test "numbers all subcommand" {
    const output = try execWithInput("255", "all");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "bin: 0b11111111") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "oct: 0o377") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "dec: 255") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hex: 0xff") != null);
}

test "numbers default is all" {
    const output = try execWithInput("16", null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "bin: 0b10000") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "oct: 0o20") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "dec: 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hex: 0x10") != null);
}

test "numbers invalid input" {
    const result = execWithInput("not_a_number", "dec");
    try std.testing.expectError(error.InvalidInput, result);
}

test "numbers unknown subcommand" {
    const result = execWithInput("42", "roman");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "numbers large value" {
    // 2^32 = 4294967296
    const output = try execWithInput("4294967296", "hex");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("0x100000000", trimmed);
}

test "numbers command struct fields" {
    try std.testing.expectEqualStrings("numbers", command.name);
    try std.testing.expectEqual(registry.Category.dev, command.category);
    try std.testing.expectEqual(@as(usize, 5), command.subcommands.len);
}

test "parseNumber decimal" {
    try std.testing.expectEqual(@as(u64, 42), parseNumber("42").?);
}

test "parseNumber hex prefix" {
    try std.testing.expectEqual(@as(u64, 255), parseNumber("0xff").?);
    try std.testing.expectEqual(@as(u64, 255), parseNumber("0XFF").?);
}

test "parseNumber binary prefix" {
    try std.testing.expectEqual(@as(u64, 10), parseNumber("0b1010").?);
    try std.testing.expectEqual(@as(u64, 10), parseNumber("0B1010").?);
}

test "parseNumber octal prefix" {
    try std.testing.expectEqual(@as(u64, 15), parseNumber("0o17").?);
    try std.testing.expectEqual(@as(u64, 15), parseNumber("0O17").?);
}

test "parseNumber whitespace trimming" {
    try std.testing.expectEqual(@as(u64, 42), parseNumber("  42  ").?);
}

test "parseNumber invalid returns null" {
    try std.testing.expect(parseNumber("abc") == null);
    try std.testing.expect(parseNumber("") == null);
}
