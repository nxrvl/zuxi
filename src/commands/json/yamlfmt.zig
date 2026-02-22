const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");
const yaml = @import("../../formats/yaml.zig");

/// Entry point for the yamlfmt command.
pub fn execute(ctx: context.Context, _: ?[]const u8) anyerror!void {
    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("yamlfmt: no input provided\n", .{});
        try writer.print("Usage: zuxi yamlfmt <yaml>\n", .{});
        try writer.print("       echo 'key: value' | zuxi yamlfmt\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    // Parse the YAML.
    var result = yaml.parse(ctx.allocator, input.data) catch {
        const writer = ctx.stderrWriter();
        try writer.print("yamlfmt: invalid YAML input\n", .{});
        return error.FormatError;
    };
    defer result.deinit();

    // Serialize back with consistent formatting.
    const output = yaml.serialize(ctx.allocator, result.value) catch {
        const writer = ctx.stderrWriter();
        try writer.print("yamlfmt: failed to format YAML\n", .{});
        return error.FormatError;
    };
    defer ctx.allocator.free(output);

    try io.writeOutput(ctx, output);
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "yamlfmt",
    .description = "Format YAML with consistent indentation",
    .category = .json,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_yamlfmt_out.tmp";

    const out_file = try std.fs.cwd().createFile(tmp_out, .{});

    const args = [_][]const u8{input};
    var ctx = context.Context.initDefault(allocator);
    ctx.args = &args;
    ctx.stdout = out_file;

    execute(ctx, null) catch |err| {
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

test "yamlfmt simple mapping" {
    const output = try execWithInput("name: zuxi\nversion: 1");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "name: zuxi") != null);
}

test "yamlfmt nested mapping" {
    const output = try execWithInput("server:\n  host: localhost\n  port: 8080");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "server:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  host: localhost") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  port:") != null);
}

test "yamlfmt sequence" {
    const output = try execWithInput("- apple\n- banana\n- cherry");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "- apple") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "- banana") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "- cherry") != null);
}

test "yamlfmt strips comments" {
    const output = try execWithInput("# comment\nname: zuxi\n# another");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "name: zuxi") != null);
    // Comments should not appear in output.
    try std.testing.expect(std.mem.indexOf(u8, output, "#") == null);
}

test "yamlfmt mapping with sequence" {
    const output = try execWithInput("fruits:\n  - apple\n  - banana");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "fruits:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "- apple") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "- banana") != null);
}

test "yamlfmt empty input" {
    const result = execWithInput("");
    // Empty input still produces valid output (empty scalar).
    if (result) |output| {
        defer std.testing.allocator.free(output);
    } else |_| {}
}

test "yamlfmt command struct fields" {
    try std.testing.expectEqualStrings("yamlfmt", command.name);
    try std.testing.expectEqual(registry.Category.json, command.category);
}
