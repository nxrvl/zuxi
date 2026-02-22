const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");
const yaml = @import("../../formats/yaml.zig");
const toml = @import("../../formats/toml.zig");

/// Entry point for the yaml2toml command.
pub fn execute(ctx: context.Context, _: ?[]const u8) anyerror!void {
    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("yaml2toml: no input provided\n", .{});
        try writer.print("Usage: zuxi yaml2toml '<yaml>'\n", .{});
        try writer.print("       cat config.yaml | zuxi yaml2toml\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    // Parse YAML input.
    var result = yaml.parse(ctx.allocator, input.data) catch {
        const writer = ctx.stderrWriter();
        try writer.print("yaml2toml: invalid YAML input\n", .{});
        return error.FormatError;
    };
    defer result.deinit();

    // Convert YAML -> JSON value (intermediate).
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const json_val = yaml.toJsonValue(arena.allocator(), result.value) catch {
        const writer = ctx.stderrWriter();
        try writer.print("yaml2toml: YAML to JSON conversion failed\n", .{});
        return error.FormatError;
    };

    // Convert JSON -> TOML value.
    const toml_val = toml.fromJsonValue(arena.allocator(), json_val) catch {
        const writer = ctx.stderrWriter();
        try writer.print("yaml2toml: JSON to TOML conversion failed\n", .{});
        return error.FormatError;
    };

    // Serialize to TOML text.
    const output = toml.serialize(arena.allocator(), toml_val) catch {
        const writer = ctx.stderrWriter();
        try writer.print("yaml2toml: serialization failed\n", .{});
        return error.FormatError;
    };

    try io.writeOutput(ctx, output);
}

pub const command = registry.Command{
    .name = "yaml2toml",
    .description = "Convert YAML to TOML",
    .category = .json,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_yaml2toml_out.tmp";

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

test "yaml2toml simple mapping" {
    const output = try execWithInput("name: zuxi\nport: 8080");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "name = \"zuxi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "port = 8080") != null);
}

test "yaml2toml nested mapping" {
    const output = try execWithInput("server:\n  host: localhost\n  port: 8080");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "[server]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "host = \"localhost\"") != null);
}

test "yaml2toml boolean" {
    const output = try execWithInput("debug: true\nverbose: false");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "debug = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "verbose = false") != null);
}

test "yaml2toml command struct" {
    try std.testing.expectEqualStrings("yaml2toml", command.name);
    try std.testing.expectEqual(registry.Category.json, command.category);
}
