const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");
const toml = @import("../../formats/toml.zig");
const yaml = @import("../../formats/yaml.zig");

/// Entry point for the toml2yaml command.
pub fn execute(ctx: context.Context, _: ?[]const u8) anyerror!void {
    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("toml2yaml: no input provided\n", .{});
        try writer.print("Usage: zuxi toml2yaml '<toml>'\n", .{});
        try writer.print("       cat config.toml | zuxi toml2yaml\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    // Parse TOML input.
    var result = toml.parse(ctx.allocator, input.data) catch {
        const writer = ctx.stderrWriter();
        try writer.print("toml2yaml: invalid TOML input\n", .{});
        return error.FormatError;
    };
    defer result.deinit();

    // Convert TOML -> JSON value (intermediate).
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const json_val = toml.toJsonValue(arena.allocator(), result.value) catch {
        const writer = ctx.stderrWriter();
        try writer.print("toml2yaml: TOML to JSON conversion failed\n", .{});
        return error.FormatError;
    };

    // Convert JSON -> YAML value.
    const yaml_val = yaml.fromJsonValue(arena.allocator(), json_val) catch {
        const writer = ctx.stderrWriter();
        try writer.print("toml2yaml: JSON to YAML conversion failed\n", .{});
        return error.FormatError;
    };

    // Serialize to YAML text.
    const output = yaml.serialize(arena.allocator(), yaml_val) catch {
        const writer = ctx.stderrWriter();
        try writer.print("toml2yaml: serialization failed\n", .{});
        return error.FormatError;
    };

    try io.writeOutput(ctx, output);
}

pub const command = registry.Command{
    .name = "toml2yaml",
    .description = "Convert TOML to YAML",
    .category = .json,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_toml2yaml_out.tmp";

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

test "toml2yaml simple key-values" {
    const output = try execWithInput("name = \"zuxi\"\nport = 8080\n");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "name: zuxi") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "port:") != null);
}

test "toml2yaml with table" {
    const output = try execWithInput("[server]\nhost = \"localhost\"\nport = 8080\n");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "server:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "host: localhost") != null);
}

test "toml2yaml boolean" {
    const output = try execWithInput("debug = true\nverbose = false\n");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "debug:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "verbose:") != null);
}

test "toml2yaml invalid input" {
    const result = execWithInput("= no key");
    try std.testing.expectError(error.FormatError, result);
}

test "toml2yaml command struct" {
    try std.testing.expectEqualStrings("toml2yaml", command.name);
    try std.testing.expectEqual(registry.Category.json, command.category);
}
