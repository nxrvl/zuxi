const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");
const color = @import("../../core/color.zig");

/// Entry point for the jwt command.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    const sub = subcommand orelse "decode";

    if (std.mem.eql(u8, sub, "generate")) {
        try doGenerate(ctx);
        return;
    }

    if (!std.mem.eql(u8, sub, "decode")) {
        const writer = ctx.stderrWriter();
        try writer.print("jwt: unknown subcommand '{s}'\n", .{sub});
        try writer.print("Available subcommands: decode, generate\n", .{});
        return error.InvalidArgument;
    }

    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("jwt: no input provided\n", .{});
        try writer.print("Usage: zuxi jwt [decode] <token>\n", .{});
        try writer.print("       echo '<token>' | zuxi jwt decode\n", .{});
        try writer.print("       zuxi jwt generate [bytes]\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    try doDecode(ctx, input.data);
}

/// Generate a cryptographically secure JWT secret key.
/// Default: 32 bytes (256-bit, suitable for HS256).
/// Optional arg: byte length (e.g. 48 for HS384, 64 for HS512).
fn doGenerate(ctx: context.Context) anyerror!void {
    var key_len: usize = 32; // default 256-bit

    if (ctx.args.len > 0) {
        key_len = std.fmt.parseInt(usize, ctx.args[0], 10) catch {
            const writer = ctx.stderrWriter();
            try writer.print("jwt generate: invalid length '{s}'\n", .{ctx.args[0]});
            try writer.print("Usage: zuxi jwt generate [bytes]\n", .{});
            try writer.print("       bytes: 32 (HS256, default), 48 (HS384), 64 (HS512)\n", .{});
            return error.InvalidArgument;
        };
        if (key_len == 0 or key_len > 128) {
            const writer = ctx.stderrWriter();
            try writer.print("jwt generate: length must be between 1 and 128 bytes\n", .{});
            return error.InvalidArgument;
        }
    }

    var key_buf: [128]u8 = undefined;
    const key = key_buf[0..key_len];
    std.crypto.random.bytes(key);

    // Encode as base64.
    const Encoder = std.base64.standard.Encoder;
    var b64_buf: [176]u8 = undefined; // ceil(128 * 4/3) = 172, +4 padding
    const b64_len = Encoder.calcSize(key_len);
    const b64 = b64_buf[0..b64_len];
    _ = Encoder.encode(b64, key);

    var out_buf: [177]u8 = undefined;
    @memcpy(out_buf[0..b64_len], b64);
    out_buf[b64_len] = '\n';
    try io.writeOutput(ctx, out_buf[0 .. b64_len + 1]);
}

/// Decode a JWT token and display header, payload, and expiration info.
fn doDecode(ctx: context.Context, token: []const u8) anyerror!void {
    // Split into parts by '.'.
    var parts: [3][]const u8 = undefined;
    var part_count: usize = 0;
    var start: usize = 0;
    for (token, 0..) |c, i| {
        if (c == '.') {
            if (part_count >= 3) {
                const writer = ctx.stderrWriter();
                try writer.print("jwt: invalid token format (too many segments)\n", .{});
                return error.FormatError;
            }
            parts[part_count] = token[start..i];
            part_count += 1;
            start = i + 1;
        }
    }
    if (part_count < 2) {
        const writer = ctx.stderrWriter();
        try writer.print("jwt: invalid token format (expected header.payload.signature)\n", .{});
        return error.FormatError;
    }
    // Last segment (signature).
    if (part_count < 3) {
        parts[part_count] = token[start..];
        part_count += 1;
    } else if (start < token.len) {
        // Unconsumed content after 3 dots means 4+ segments
        const writer = ctx.stderrWriter();
        try writer.print("jwt: invalid token format (expected header.payload.signature)\n", .{});
        return error.FormatError;
    }
    if (part_count != 3) {
        const writer = ctx.stderrWriter();
        try writer.print("jwt: invalid token format (expected 3 segments)\n", .{});
        return error.FormatError;
    }

    // Decode header.
    const header_json = base64UrlDecode(ctx.allocator, parts[0]) catch {
        const writer = ctx.stderrWriter();
        try writer.print("jwt: failed to decode header (invalid base64)\n", .{});
        return error.FormatError;
    };
    defer ctx.allocator.free(header_json);

    // Decode payload.
    const payload_json = base64UrlDecode(ctx.allocator, parts[1]) catch {
        const writer = ctx.stderrWriter();
        try writer.print("jwt: failed to decode payload (invalid base64)\n", .{});
        return error.FormatError;
    };
    defer ctx.allocator.free(payload_json);

    // Format header as pretty JSON.
    const header_pretty = formatJson(ctx.allocator, header_json) catch {
        const writer = ctx.stderrWriter();
        try writer.print("jwt: header is not valid JSON\n", .{});
        return error.FormatError;
    };
    defer ctx.allocator.free(header_pretty);

    // Format payload as pretty JSON.
    const payload_pretty = formatJson(ctx.allocator, payload_json) catch {
        const writer = ctx.stderrWriter();
        try writer.print("jwt: payload is not valid JSON\n", .{});
        return error.FormatError;
    };
    defer ctx.allocator.free(payload_pretty);

    // Build output.
    const no_color = !color.shouldColor(ctx);
    var output = std.ArrayList(u8){};
    defer output.deinit(ctx.allocator);
    const w = output.writer(ctx.allocator);

    try color.colorize(w, "=== Header ===", color.bold, no_color);
    try w.writeByte('\n');
    try color.writeColoredJson(w, header_pretty, no_color);
    try w.writeByte('\n');

    try w.writeByte('\n');
    try color.colorize(w, "=== Payload ===", color.bold, no_color);
    try w.writeByte('\n');
    try color.writeColoredJson(w, payload_pretty, no_color);
    try w.writeByte('\n');

    // Extract timestamp fields from payload.
    if (std.json.parseFromSlice(std.json.Value, ctx.allocator, payload_json, .{})) |parsed| {
        defer parsed.deinit();
        if (parsed.value == .object) {
            const obj = parsed.value.object;
            try writeTimestamp(w, obj, "iat", "Issued At", no_color);
            try writeTimestamp(w, obj, "exp", "Expires At", no_color);
            try writeTimestamp(w, obj, "nbf", "Not Before", no_color);

            // Check expiration.
            if (obj.get("exp")) |exp_val| {
                if (exp_val == .integer) {
                    const exp_ts = exp_val.integer;
                    const now_ts: i64 = @intCast(@divTrunc(std.time.milliTimestamp(), 1000));
                    try w.writeByte('\n');
                    if (exp_ts < now_ts) {
                        try color.colorize(w, "Status: EXPIRED", color.red, no_color);
                        try w.print(" (expired {d} seconds ago)\n", .{now_ts - exp_ts});
                    } else {
                        try color.colorize(w, "Status: NOT EXPIRED", color.green, no_color);
                        try w.print(" (expires in {d} seconds)\n", .{exp_ts - now_ts});
                    }
                    try w.print("Note: signature not verified (decode only)\n", .{});
                }
            }
        }
    } else |_| {}

    try w.writeByte('\n');
    try color.colorize(w, "=== Signature ===", color.bold, no_color);
    try w.print("\n{s}\n", .{parts[2]});

    try io.writeOutput(ctx, output.items);
}

/// Write a human-readable timestamp line for a JWT claim.
fn writeTimestamp(w: anytype, obj: std.json.ObjectMap, key: []const u8, label: []const u8, no_color: bool) !void {
    if (obj.get(key)) |val| {
        if (val == .integer) {
            const ts = val.integer;
            if (ts < 0) return;
            const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(ts) };
            const day = epoch.getDaySeconds();
            const yd = epoch.getEpochDay().calculateYearDay();
            const md = yd.calculateMonthDay();
            try w.writeByte('\n');
            try color.colorize(w, label, color.cyan, no_color);
            try w.print(": {d} ({d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC)", .{
                ts,
                yd.year,
                @intFromEnum(md.month),
                md.day_index + 1,
                day.getHoursIntoDay(),
                day.getMinutesIntoHour(),
                day.getSecondsIntoMinute(),
            });
        }
    }
}

/// Decode a base64url-encoded string (no padding required).
fn base64UrlDecode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Convert base64url to standard base64: replace - with +, _ with /.
    const padded_len = (data.len + 3) / 4 * 4; // Round up to multiple of 4.
    const buf = try allocator.alloc(u8, padded_len);
    defer allocator.free(buf);

    for (data, 0..) |c, i| {
        buf[i] = switch (c) {
            '-' => '+',
            '_' => '/',
            else => c,
        };
    }
    // Add padding.
    for (data.len..padded_len) |i| {
        buf[i] = '=';
    }

    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(buf) catch return error.InvalidInput;
    const result = try allocator.alloc(u8, decoded_len);
    decoder.decode(result, buf) catch {
        allocator.free(result);
        return error.InvalidInput;
    };
    return result;
}

/// Pretty-print JSON with 2-space indentation.
fn formatJson(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return error.FormatError;
    defer parsed.deinit();

    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{
        .whitespace = .indent_2,
    }) catch return error.OutOfMemory;
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "jwt",
    .description = "Decode and inspect JWT tokens, generate secret keys",
    .category = .security,
    .subcommands = &.{ "decode", "generate" },
    .execute = execute,
};

// --- Tests ---

fn execGenerate(length_arg: ?[]const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_jwt_gen.tmp";
    const tmp_in = "zuxi_test_jwt_gen_in.tmp";

    const out_file = try std.fs.cwd().createFile(tmp_out, .{});

    // Create an empty stdin file so getInput won't block.
    const empty_in = try std.fs.cwd().createFile(tmp_in, .{});
    empty_in.close();
    const stdin_file = try std.fs.cwd().openFile(tmp_in, .{});

    var args_buf: [1][]const u8 = undefined;
    var args_slice: []const []const u8 = &.{};
    if (length_arg) |arg| {
        args_buf[0] = arg;
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

fn execWithInput(input: []const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_jwt_out.tmp";

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

// Test JWT: {"alg":"HS256","typ":"JWT"}.{"sub":"1234567890","name":"John Doe","iat":1516239022}.signature
// eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c
const test_token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";

test "jwt decode shows header" {
    const output = try execWithInput(test_token, "decode");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "=== Header ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "HS256") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "JWT") != null);
}

test "jwt decode shows payload" {
    const output = try execWithInput(test_token, "decode");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "=== Payload ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "1234567890") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "John Doe") != null);
}

test "jwt decode shows iat timestamp" {
    const output = try execWithInput(test_token, "decode");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Issued At") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "1516239022") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2018") != null); // Year from the iat
}

test "jwt decode shows signature" {
    const output = try execWithInput(test_token, "decode");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "=== Signature ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c") != null);
}

test "jwt decode default subcommand" {
    const output = try execWithInput(test_token, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "=== Header ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "=== Payload ===") != null);
}

// Token with exp in the past: {"alg":"HS256"}.{"exp":1000000000}.sig
const expired_token = "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjEwMDAwMDAwMDB9.sig";

test "jwt decode expired token shows EXPIRED" {
    const output = try execWithInput(expired_token, "decode");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "EXPIRED") != null);
}

test "jwt decode invalid token format" {
    const result = execWithInput("not-a-jwt-token", "decode");
    try std.testing.expectError(error.FormatError, result);
}

test "jwt decode too few segments" {
    const result = execWithInput("onlyone", "decode");
    try std.testing.expectError(error.FormatError, result);
}

test "jwt decode too many segments" {
    const result = execWithInput("a.b.c.d", "decode");
    try std.testing.expectError(error.FormatError, result);
}

test "jwt unknown subcommand" {
    const result = execWithInput(test_token, "verify");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "jwt generate produces base64 output" {
    const output = try execGenerate(null, "generate");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    // Default 32 bytes -> 44 base64 chars
    try std.testing.expectEqual(@as(usize, 44), trimmed.len);
    // Validate it's valid base64.
    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(trimmed) catch unreachable;
    const decoded = try std.testing.allocator.alloc(u8, decoded_len);
    defer std.testing.allocator.free(decoded);
    decoder.decode(decoded, trimmed) catch unreachable;
    try std.testing.expectEqual(@as(usize, 32), decoded_len);
}

test "jwt generate custom length 64" {
    const output = try execGenerate("64", "generate");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    // 64 bytes -> 88 base64 chars
    try std.testing.expectEqual(@as(usize, 88), trimmed.len);
}

test "jwt generate custom length 48" {
    const output = try execGenerate("48", "generate");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    // 48 bytes -> 64 base64 chars
    try std.testing.expectEqual(@as(usize, 64), trimmed.len);
}

test "jwt generate produces unique keys" {
    const output1 = try execGenerate(null, "generate");
    defer std.testing.allocator.free(output1);
    const output2 = try execGenerate(null, "generate");
    defer std.testing.allocator.free(output2);
    try std.testing.expect(!std.mem.eql(u8, output1, output2));
}

test "jwt generate invalid length" {
    const result = execGenerate("abc", "generate");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "jwt generate zero length" {
    const result = execGenerate("0", "generate");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "jwt generate too large length" {
    const result = execGenerate("256", "generate");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "jwt decode no ANSI codes in file output" {
    // When stdout is a file (not TTY), output should never contain ANSI escape codes.
    const output = try execWithInput(test_token, "decode");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
    // Should still contain all expected sections.
    try std.testing.expect(std.mem.indexOf(u8, output, "=== Header ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "=== Payload ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "=== Signature ===") != null);
}

test "jwt decode with explicit no_color flag" {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_jwt_nocolor.tmp";
    const out_file = try std.fs.cwd().createFile(tmp_out, .{});

    const args = [_][]const u8{test_token};
    var ctx = context.Context.initDefault(allocator);
    ctx.args = &args;
    ctx.stdout = out_file;
    ctx.flags.no_color = true;

    execute(ctx, "decode") catch |err| {
        out_file.close();
        std.fs.cwd().deleteFile(tmp_out) catch {};
        return err;
    };
    out_file.close();

    const file = try std.fs.cwd().openFile(tmp_out, .{});
    defer file.close();
    defer std.fs.cwd().deleteFile(tmp_out) catch {};
    const output = try file.readToEndAlloc(allocator, io.max_input_size);
    defer allocator.free(output);
    // No ANSI codes when no_color is set.
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Issued At") != null);
}

test "jwt decode expired token no ANSI codes" {
    const output = try execWithInput(expired_token, "decode");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "EXPIRED") != null);
}

test "jwt command struct fields" {
    try std.testing.expectEqualStrings("jwt", command.name);
    try std.testing.expectEqual(registry.Category.security, command.category);
    try std.testing.expectEqual(@as(usize, 2), command.subcommands.len);
}

test "base64UrlDecode basic" {
    const result = try base64UrlDecode(std.testing.allocator, "SGVsbG8");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "base64UrlDecode with url-safe chars" {
    // base64url uses - instead of + and _ instead of /
    const result = try base64UrlDecode(std.testing.allocator, "PDw_Pz4-");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<<??>>", result);
}
