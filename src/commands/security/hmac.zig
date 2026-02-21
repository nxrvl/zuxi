const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

const Algorithm = enum { sha256, sha512 };

/// Entry point for the hmac command.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    const algo: Algorithm = if (subcommand) |sub| blk: {
        if (std.mem.eql(u8, sub, "sha256")) break :blk .sha256;
        if (std.mem.eql(u8, sub, "sha512")) break :blk .sha512;
        const writer = ctx.stderrWriter();
        try writer.print("hmac: unknown subcommand '{s}'\n", .{sub});
        try writer.print("Available subcommands: sha256, sha512\n", .{});
        return error.InvalidArgument;
    } else .sha256;

    // Parse key and data from positional args.
    // Usage: zuxi hmac [sha256|sha512] <data> <key>
    // Or: echo 'data' | zuxi hmac sha256 <key>
    var data: ?[]const u8 = null;
    var key: ?[]const u8 = null;
    var allocated_data = false;

    if (ctx.args.len >= 2) {
        // Both data and key from args.
        data = ctx.args[0];
        key = ctx.args[1];
    } else if (ctx.args.len == 1) {
        // Key from arg, data from stdin.
        key = ctx.args[0];
        if (!io.isTty(ctx.stdin)) {
            const stdin_data = try io.readAllTrimmed(ctx.stdin, ctx.allocator);
            data = stdin_data;
            allocated_data = true;
        }
    }

    if (key == null or data == null) {
        const writer = ctx.stderrWriter();
        try writer.print("hmac: missing data or key\n", .{});
        try writer.print("Usage: zuxi hmac [sha256|sha512] <data> <key>\n", .{});
        try writer.print("       echo 'data' | zuxi hmac sha256 <key>\n", .{});
        return error.MissingArgument;
    }

    defer if (allocated_data) ctx.allocator.free(@constCast(data.?));

    switch (algo) {
        .sha256 => try doHmac(std.crypto.auth.hmac.sha2.HmacSha256, ctx, data.?, key.?),
        .sha512 => try doHmac(std.crypto.auth.hmac.sha2.HmacSha512, ctx, data.?, key.?),
    }
}

/// Compute and output the HMAC hex digest.
fn doHmac(comptime HmacType: type, ctx: context.Context, data: []const u8, key: []const u8) anyerror!void {
    var mac: [HmacType.mac_length]u8 = undefined;
    HmacType.create(&mac, data, key);

    // Format as lowercase hex string.
    const hex = std.fmt.bytesToHex(mac, .lower);
    const hex_len = hex.len;

    var out_buf: [129]u8 = undefined;
    @memcpy(out_buf[0..hex_len], &hex);
    out_buf[hex_len] = '\n';
    try io.writeOutput(ctx, out_buf[0 .. hex_len + 1]);
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "hmac",
    .description = "Compute HMAC signatures (SHA-256, SHA-512)",
    .category = .security,
    .subcommands = &.{ "sha256", "sha512" },
    .execute = execute,
};

// --- Tests ---

fn execWithInput(data_arg: []const u8, key_arg: []const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_hmac_out.tmp";

    const out_file = try std.fs.cwd().createFile(tmp_out, .{});

    const args = [_][]const u8{ data_arg, key_arg };
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

test "hmac sha256 known value" {
    // HMAC-SHA256("test", "secret") - known test vector.
    const output = try execWithInput("test", "secret", "sha256");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    // Verify it's a 64-char hex string (SHA-256 = 32 bytes = 64 hex chars).
    try std.testing.expectEqual(@as(usize, 64), trimmed.len);
    // Verify known value: HMAC-SHA256("test", "secret")
    try std.testing.expectEqualStrings(
        "0329a06b62cd16b33eb6792be8c60b158d89a2ee3a876fce9a881ebb488c0914",
        trimmed,
    );
}

test "hmac sha256 default subcommand" {
    const output = try execWithInput("test", "secret", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings(
        "0329a06b62cd16b33eb6792be8c60b158d89a2ee3a876fce9a881ebb488c0914",
        trimmed,
    );
}

test "hmac sha512 known value" {
    const output = try execWithInput("test", "secret", "sha512");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    // SHA-512 HMAC = 64 bytes = 128 hex chars.
    try std.testing.expectEqual(@as(usize, 128), trimmed.len);
}

test "hmac sha256 empty data" {
    const output = try execWithInput("", "secret", "sha256");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqual(@as(usize, 64), trimmed.len);
}

test "hmac sha256 empty key" {
    const output = try execWithInput("test", "", "sha256");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqual(@as(usize, 64), trimmed.len);
}

test "hmac unknown subcommand" {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_hmac_err.tmp";

    const out_file = try std.fs.cwd().createFile(tmp_out, .{});

    const args = [_][]const u8{ "test", "secret" };
    var ctx = context.Context.initDefault(allocator);
    ctx.args = &args;
    ctx.stdout = out_file;

    const result = execute(ctx, "md5");
    out_file.close();
    std.fs.cwd().deleteFile(tmp_out) catch {};
    try std.testing.expectError(error.InvalidArgument, result);
}

test "hmac different keys produce different macs" {
    const output1 = try execWithInput("data", "key1", "sha256");
    defer std.testing.allocator.free(output1);
    const output2 = try execWithInput("data", "key2", "sha256");
    defer std.testing.allocator.free(output2);
    // Different keys should produce different outputs.
    try std.testing.expect(!std.mem.eql(u8, output1, output2));
}

test "hmac different data produce different macs" {
    const output1 = try execWithInput("data1", "key", "sha256");
    defer std.testing.allocator.free(output1);
    const output2 = try execWithInput("data2", "key", "sha256");
    defer std.testing.allocator.free(output2);
    try std.testing.expect(!std.mem.eql(u8, output1, output2));
}

test "hmac command struct fields" {
    try std.testing.expectEqualStrings("hmac", command.name);
    try std.testing.expectEqual(registry.Category.security, command.category);
    try std.testing.expectEqual(@as(usize, 2), command.subcommands.len);
}
