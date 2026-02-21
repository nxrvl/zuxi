const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// Entry point for the jwt command.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    if (subcommand) |sub| {
        if (!std.mem.eql(u8, sub, "decode")) {
            const writer = ctx.stderrWriter();
            try writer.print("jwt: unknown subcommand '{s}'\n", .{sub});
            try writer.print("Available subcommands: decode\n", .{});
            return error.InvalidArgument;
        }
    }

    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("jwt: no input provided\n", .{});
        try writer.print("Usage: zuxi jwt [decode] <token>\n", .{});
        try writer.print("       echo '<token>' | zuxi jwt decode\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    try doDecode(ctx, input.data);
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
    var output = std.ArrayList(u8){};
    defer output.deinit(ctx.allocator);
    const w = output.writer(ctx.allocator);

    try w.print("=== Header ===\n{s}\n", .{header_pretty});
    try w.print("\n=== Payload ===\n{s}\n", .{payload_pretty});

    // Extract timestamp fields from payload.
    if (std.json.parseFromSlice(std.json.Value, ctx.allocator, payload_json, .{})) |parsed| {
        defer parsed.deinit();
        if (parsed.value == .object) {
            const obj = parsed.value.object;
            try writeTimestamp(w, obj, "iat", "Issued At");
            try writeTimestamp(w, obj, "exp", "Expires At");
            try writeTimestamp(w, obj, "nbf", "Not Before");

            // Check expiration.
            if (obj.get("exp")) |exp_val| {
                if (exp_val == .integer) {
                    const exp_ts = exp_val.integer;
                    const now_ts: i64 = @intCast(@divTrunc(std.time.milliTimestamp(), 1000));
                    try w.writeByte('\n');
                    if (exp_ts < now_ts) {
                        try w.print("Status: EXPIRED (expired {d} seconds ago)\n", .{now_ts - exp_ts});
                    } else {
                        try w.print("Status: VALID (expires in {d} seconds)\n", .{exp_ts - now_ts});
                    }
                }
            }
        }
    } else |_| {}

    try w.print("\n=== Signature ===\n{s}\n", .{parts[2]});

    try io.writeOutput(ctx, output.items);
}

/// Write a human-readable timestamp line for a JWT claim.
fn writeTimestamp(w: anytype, obj: std.json.ObjectMap, key: []const u8, label: []const u8) !void {
    if (obj.get(key)) |val| {
        if (val == .integer) {
            const ts = val.integer;
            if (ts < 0) return;
            const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(ts) };
            const day = epoch.getDaySeconds();
            const yd = epoch.getEpochDay().calculateYearDay();
            const md = yd.calculateMonthDay();
            try w.print("\n{s}: {d} ({d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC)", .{
                label,
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
    .description = "Decode and inspect JWT tokens",
    .category = .security,
    .subcommands = &.{"decode"},
    .execute = execute,
};

// --- Tests ---

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

test "jwt unknown subcommand" {
    const result = execWithInput(test_token, "verify");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "jwt command struct fields" {
    try std.testing.expectEqualStrings("jwt", command.name);
    try std.testing.expectEqual(registry.Category.security, command.category);
    try std.testing.expectEqual(@as(usize, 1), command.subcommands.len);
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
