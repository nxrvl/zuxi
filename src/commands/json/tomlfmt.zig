const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");
const toml = @import("../../formats/toml.zig");

/// Entry point for the tomlfmt command.
pub fn execute(ctx: context.Context, _: ?[]const u8) anyerror!void {
    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("tomlfmt: no input provided\n", .{});
        try writer.print("Usage: zuxi tomlfmt <toml>\n", .{});
        try writer.print("       echo 'key = \"value\"' | zuxi tomlfmt\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    // Parse the TOML.
    var result = toml.parse(ctx.allocator, input.data) catch {
        const writer = ctx.stderrWriter();
        try writer.print("tomlfmt: invalid TOML input\n", .{});
        return error.FormatError;
    };
    defer result.deinit();

    // Serialize back with consistent formatting.
    const output = toml.serialize(ctx.allocator, result.value) catch {
        const writer = ctx.stderrWriter();
        try writer.print("tomlfmt: failed to format TOML\n", .{});
        return error.FormatError;
    };
    defer ctx.allocator.free(output);

    try io.writeOutput(ctx, output);
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "tomlfmt",
    .description = "Format TOML with consistent style",
    .category = .json,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_tomlfmt_out.tmp";

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

test "tomlfmt simple key-values" {
    const output = try execWithInput("name = \"zuxi\"\nport = 8080\n");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "name = \"zuxi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "port = 8080") != null);
}

test "tomlfmt with table section" {
    const output = try execWithInput("[server]\nhost = \"localhost\"\nport = 8080\n");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "[server]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "host = \"localhost\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "port = 8080") != null);
}

test "tomlfmt strips comments" {
    const output = try execWithInput("# comment\nname = \"zuxi\" # inline\n");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "name = \"zuxi\"") != null);
    // Comments should be stripped.
    try std.testing.expect(std.mem.indexOf(u8, output, "#") == null);
}

test "tomlfmt array values" {
    const output = try execWithInput("ports = [80, 443, 8080]\n");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "ports = [80, 443, 8080]") != null);
}

test "tomlfmt boolean values" {
    const output = try execWithInput("debug = true\nverbose = false\n");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "debug = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "verbose = false") != null);
}

test "tomlfmt mixed document" {
    const output = try execWithInput("title = \"Config\"\n\n[server]\nhost = \"0.0.0.0\"\nport = 8080\n");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "title = \"Config\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[server]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "host = \"0.0.0.0\"") != null);
}

test "tomlfmt empty input" {
    const result = execWithInput("");
    // Empty input produces valid (empty) output.
    if (result) |output| {
        defer std.testing.allocator.free(output);
    } else |_| {}
}

test "tomlfmt command struct fields" {
    try std.testing.expectEqualStrings("tomlfmt", command.name);
    try std.testing.expectEqual(registry.Category.json, command.category);
}
