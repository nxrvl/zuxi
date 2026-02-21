const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");
const color = @import("../../core/color.zig");

/// JSON formatting mode.
const Mode = enum {
    prettify,
    minify,
    validate,
};

/// Entry point for the jsonfmt command.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    const mode: Mode = if (subcommand) |sub| blk: {
        if (std.mem.eql(u8, sub, "minify")) break :blk .minify;
        if (std.mem.eql(u8, sub, "validate")) break :blk .validate;
        if (std.mem.eql(u8, sub, "prettify")) break :blk .prettify;
        const writer = ctx.stderrWriter();
        try writer.print("jsonfmt: unknown subcommand '{s}'\n", .{sub});
        try writer.print("Available subcommands: prettify, minify, validate\n", .{});
        return error.InvalidArgument;
    } else .prettify;

    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("jsonfmt: no input provided\n", .{});
        try writer.print("Usage: zuxi jsonfmt [prettify|minify|validate] <json>\n", .{});
        try writer.print("       echo '{{...}}' | zuxi jsonfmt\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    switch (mode) {
        .validate => try doValidate(ctx, input.data),
        .prettify => try doFormatPrettify(ctx, input.data),
        .minify => try doFormatMinify(ctx, input.data),
    }
}

/// Parse JSON input and return the parsed value. Returns FormatError on invalid JSON.
fn parseJson(ctx: context.Context, data: []const u8) anyerror!std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, ctx.allocator, data, .{}) catch {
        const writer = ctx.stderrWriter();
        try writer.print("jsonfmt: invalid JSON input\n", .{});
        return error.FormatError;
    };
}

/// Pretty-print JSON with 4-space indentation, with optional syntax highlighting.
fn doFormatPrettify(ctx: context.Context, data: []const u8) anyerror!void {
    const parsed = try parseJson(ctx, data);
    defer parsed.deinit();

    const json_str = std.json.Stringify.valueAlloc(ctx.allocator, parsed.value, .{
        .whitespace = .indent_4,
    }) catch return error.OutOfMemory;
    defer ctx.allocator.free(json_str);

    if (color.shouldColor(ctx)) {
        const stdout = ctx.stdoutWriter();
        try color.writeColoredJson(stdout, json_str, false);
        try stdout.writeByte('\n');
    } else {
        const output = try appendNewline(ctx.allocator, json_str);
        defer ctx.allocator.free(output);
        try io.writeOutput(ctx, output);
    }
}

/// Minify JSON (compact, no whitespace).
fn doFormatMinify(ctx: context.Context, data: []const u8) anyerror!void {
    const parsed = try parseJson(ctx, data);
    defer parsed.deinit();

    const json_str = std.json.Stringify.valueAlloc(ctx.allocator, parsed.value, .{
        .whitespace = .minified,
    }) catch return error.OutOfMemory;
    defer ctx.allocator.free(json_str);

    const output = try appendNewline(ctx.allocator, json_str);
    defer ctx.allocator.free(output);
    try io.writeOutput(ctx, output);
}

/// Append a newline to the given string.
fn appendNewline(allocator: std.mem.Allocator, str: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, str.len + 1);
    @memcpy(result[0..str.len], str);
    result[str.len] = '\n';
    return result;
}

/// Validate JSON and report the result.
fn doValidate(ctx: context.Context, data: []const u8) anyerror!void {
    const valid = std.json.Scanner.validate(ctx.allocator, data) catch return error.OutOfMemory;
    if (valid) {
        try io.writeOutput(ctx, "Valid JSON\n");
    } else {
        const writer = ctx.stderrWriter();
        try writer.print("jsonfmt: invalid JSON\n", .{});
        return error.FormatError;
    }
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "jsonfmt",
    .description = "Format, minify, or validate JSON",
    .category = .json,
    .subcommands = &.{ "prettify", "minify", "validate" },
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_jsonfmt_out.tmp";

    // Redirect stdout to a temp file.
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

test "jsonfmt prettify compact JSON" {
    const output = try execWithInput("{\"a\":1,\"b\":2}", null);
    defer std.testing.allocator.free(output);
    // Should contain indentation
    try std.testing.expect(std.mem.indexOf(u8, output, "    ") != null);
    // Should contain the keys
    try std.testing.expect(std.mem.indexOf(u8, output, "\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"b\"") != null);
}

test "jsonfmt prettify explicit subcommand" {
    const output = try execWithInput("{\"x\":10}", "prettify");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "    ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"x\"") != null);
}

test "jsonfmt minify" {
    const input =
        \\{
        \\    "name": "zuxi",
        \\    "version": 1
        \\}
    ;
    const output = try execWithInput(input, "minify");
    defer std.testing.allocator.free(output);
    // Minified output should not contain newlines within the JSON (only trailing)
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expect(std.mem.indexOf(u8, trimmed, "\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, trimmed, "    ") == null);
    // Should still contain the data
    try std.testing.expect(std.mem.indexOf(u8, output, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"zuxi\"") != null);
}

test "jsonfmt validate valid JSON" {
    const output = try execWithInput("{\"valid\":true}", "validate");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Valid JSON") != null);
}

test "jsonfmt validate invalid JSON" {
    const result = execWithInput("{invalid json}", "validate");
    try std.testing.expectError(error.FormatError, result);
}

test "jsonfmt prettify invalid JSON" {
    const result = execWithInput("not json at all", null);
    try std.testing.expectError(error.FormatError, result);
}

test "jsonfmt minify invalid JSON" {
    const result = execWithInput("{broken", "minify");
    try std.testing.expectError(error.FormatError, result);
}

test "jsonfmt unknown subcommand" {
    const result = execWithInput("{}", "compress");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "jsonfmt prettify nested JSON" {
    const input = "{\"a\":{\"b\":{\"c\":1}},\"d\":[1,2,3]}";
    const output = try execWithInput(input, null);
    defer std.testing.allocator.free(output);
    // Should have multiple indentation levels
    try std.testing.expect(std.mem.indexOf(u8, output, "        ") != null); // 8 spaces = 2 levels
}

test "jsonfmt prettify array" {
    const output = try execWithInput("[1,2,3]", null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "3") != null);
}

test "jsonfmt minify already minified" {
    const input = "{\"a\":1}";
    const output = try execWithInput(input, "minify");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("{\"a\":1}", trimmed);
}

test "jsonfmt validate empty object" {
    const output = try execWithInput("{}", "validate");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Valid JSON") != null);
}

test "jsonfmt validate empty array" {
    const output = try execWithInput("[]", "validate");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Valid JSON") != null);
}

test "jsonfmt prettify no ANSI codes in file output" {
    // When stdout is a file (not TTY), output should never contain ANSI escape codes.
    const output = try execWithInput("{\"key\":\"value\",\"num\":42}", null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
    // Should still contain the data.
    try std.testing.expect(std.mem.indexOf(u8, output, "\"key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"value\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "42") != null);
}

test "jsonfmt prettify with explicit no_color flag" {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_jsonfmt_nocolor.tmp";
    const out_file = try std.fs.cwd().createFile(tmp_out, .{});

    const args = [_][]const u8{"{\"a\":1}"};
    var ctx = context.Context.initDefault(allocator);
    ctx.args = &args;
    ctx.stdout = out_file;
    ctx.flags.no_color = true;

    execute(ctx, null) catch |err| {
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
    try std.testing.expect(std.mem.indexOf(u8, output, "\"a\"") != null);
}

test "jsonfmt command struct fields" {
    try std.testing.expectEqualStrings("jsonfmt", command.name);
    try std.testing.expectEqual(registry.Category.json, command.category);
    try std.testing.expectEqual(@as(usize, 3), command.subcommands.len);
}
