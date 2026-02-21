const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

const Algorithm = enum { sha256, sha512, md5 };

/// Entry point for the hash command.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    const algo: Algorithm = if (subcommand) |sub| blk: {
        if (std.mem.eql(u8, sub, "sha256")) break :blk .sha256;
        if (std.mem.eql(u8, sub, "sha512")) break :blk .sha512;
        if (std.mem.eql(u8, sub, "md5")) break :blk .md5;
        const writer = ctx.stderrWriter();
        try writer.print("hash: unknown subcommand '{s}'\n", .{sub});
        try writer.print("Available subcommands: sha256, sha512, md5\n", .{});
        return error.InvalidArgument;
    } else .sha256;

    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("hash: no input provided\n", .{});
        try writer.print("Usage: zuxi hash [sha256|sha512|md5] <data>\n", .{});
        try writer.print("       echo 'data' | zuxi hash sha256\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    switch (algo) {
        .sha256 => try doHash(std.crypto.hash.sha2.Sha256, ctx, input.data),
        .sha512 => try doHash(std.crypto.hash.sha2.Sha512, ctx, input.data),
        .md5 => try doHash(std.crypto.hash.Md5, ctx, input.data),
    }
}

/// Compute and output the hex digest for the given hash algorithm.
fn doHash(comptime Hash: type, ctx: context.Context, data: []const u8) anyerror!void {
    var hasher = Hash.init(.{});
    hasher.update(data);
    var digest: [Hash.digest_length]u8 = undefined;
    hasher.final(&digest);

    // Format as lowercase hex string.
    const hex = std.fmt.bytesToHex(digest, .lower);
    const hex_len = hex.len;

    // Write hex + newline.
    var out_buf: [129]u8 = undefined;
    @memcpy(out_buf[0..hex_len], &hex);
    out_buf[hex_len] = '\n';
    try io.writeOutput(ctx, out_buf[0 .. hex_len + 1]);
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "hash",
    .description = "Compute hash digests (SHA-256, SHA-512, MD5)",
    .category = .security,
    .subcommands = &.{ "sha256", "sha512", "md5" },
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_hash_out.tmp";

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

test "hash sha256 known value" {
    // SHA-256 of "test" = 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
    const output = try execWithInput("test", "sha256");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08", trimmed);
}

test "hash sha256 default subcommand" {
    const output = try execWithInput("test", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08", trimmed);
}

test "hash sha512 known value" {
    // SHA-512 of "test"
    const output = try execWithInput("test", "sha512");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("ee26b0dd4af7e749aa1a8ee3c10ae9923f618980772e473f8819a5d4940e0db27ac185f8a0e1d5f84f88bc887fd67b143732c304cc5fa9ad8e6f57f50028a8ff", trimmed);
}

test "hash md5 known value" {
    // MD5 of "test" = 098f6bcd4621d373cade4e832627b4f6
    const output = try execWithInput("test", "md5");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("098f6bcd4621d373cade4e832627b4f6", trimmed);
}

test "hash sha256 empty string" {
    // SHA-256 of "" = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    const output = try execWithInput("", "sha256");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", trimmed);
}

test "hash unknown subcommand" {
    const result = execWithInput("test", "crc32");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "hash command struct fields" {
    try std.testing.expectEqualStrings("hash", command.name);
    try std.testing.expectEqual(registry.Category.security, command.category);
    try std.testing.expectEqual(@as(usize, 3), command.subcommands.len);
}
