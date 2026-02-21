const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");
const yaml = @import("../../formats/yaml.zig");

/// Entry point for the yamlstruct command.
pub fn execute(ctx: context.Context, _: ?[]const u8) anyerror!void {
    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("yamlstruct: no input provided\n", .{});
        try writer.print("Usage: zuxi yamlstruct <yaml>\n", .{});
        try writer.print("       echo 'key: value' | zuxi yamlstruct\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    // Parse the YAML.
    var yaml_result = yaml.parse(ctx.allocator, input.data) catch {
        const writer = ctx.stderrWriter();
        try writer.print("yamlstruct: invalid YAML input\n", .{});
        return error.FormatError;
    };
    defer yaml_result.deinit();

    // Convert YAML value tree to std.json.Value for Go struct generation.
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const json_value = yaml.toJsonValue(arena.allocator(), yaml_result.value) catch {
        const writer = ctx.stderrWriter();
        try writer.print("yamlstruct: failed to convert YAML to intermediate representation\n", .{});
        return error.FormatError;
    };

    // Generate Go struct using the same logic as jsonstruct.
    var output = std.ArrayList(u8){};
    defer output.deinit(ctx.allocator);

    try generateGoStruct(ctx.allocator, &output, "Root", json_value, 0);
    try output.append(ctx.allocator, '\n');
    try io.writeOutput(ctx, output.items);
}

/// Generate a Go struct definition from a JSON value.
/// Reuses the same logic as jsonstruct.zig.
fn generateGoStruct(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    struct_name: []const u8,
    value: std.json.Value,
    indent_level: usize,
) !void {
    switch (value) {
        .object => |obj| {
            var nested = std.ArrayList(NestedStruct){};
            defer {
                for (nested.items) |ns| {
                    allocator.free(ns.name);
                }
                nested.deinit(allocator);
            }

            try writeIndent(allocator, output, indent_level);
            try output.appendSlice(allocator, "type ");
            try output.appendSlice(allocator, struct_name);
            try output.appendSlice(allocator, " struct {\n");

            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const val = entry.value_ptr.*;

                try writeIndent(allocator, output, indent_level + 1);

                const pascal_name = try toPascalCase(allocator, key);
                defer allocator.free(pascal_name);
                try output.appendSlice(allocator, pascal_name);
                try output.append(allocator, ' ');

                const go_type = try inferGoType(allocator, key, val, &nested);
                defer allocator.free(go_type);
                try output.appendSlice(allocator, go_type);

                try output.appendSlice(allocator, " `json:\"");
                try output.appendSlice(allocator, key);
                try output.appendSlice(allocator, "\"`\n");
            }

            try writeIndent(allocator, output, indent_level);
            try output.append(allocator, '}');
            try output.append(allocator, '\n');

            for (nested.items) |ns| {
                try output.append(allocator, '\n');
                try generateGoStruct(allocator, output, ns.name, ns.value, indent_level);
            }
        },
        .array => |arr| {
            if (arr.items.len > 0) {
                const first = arr.items[0];
                if (first == .object) {
                    try generateGoStruct(allocator, output, struct_name, first, indent_level);
                } else {
                    try writeIndent(allocator, output, indent_level);
                    try output.appendSlice(allocator, "// ");
                    try output.appendSlice(allocator, struct_name);
                    try output.appendSlice(allocator, " is an array of ");
                    const elem_type = try goTypeForValue(allocator, first);
                    defer allocator.free(elem_type);
                    try output.appendSlice(allocator, elem_type);
                    try output.append(allocator, '\n');
                }
            }
        },
        else => {
            try output.appendSlice(allocator, "// Cannot generate struct from scalar value\n");
        },
    }
}

const NestedStruct = struct {
    name: []const u8,
    value: std.json.Value,
};

fn inferGoType(
    allocator: std.mem.Allocator,
    key: []const u8,
    value: std.json.Value,
    nested: *std.ArrayList(NestedStruct),
) ![]u8 {
    switch (value) {
        .object => {
            const nested_name = try toPascalCase(allocator, key);
            try nested.append(allocator, .{ .name = nested_name, .value = value });
            return try allocator.dupe(u8, nested_name);
        },
        .array => |arr| {
            if (arr.items.len > 0) {
                const first = arr.items[0];
                if (first == .object) {
                    const nested_name = try toPascalCase(allocator, key);
                    try nested.append(allocator, .{ .name = nested_name, .value = first });
                    const result = try allocator.alloc(u8, 2 + nested_name.len);
                    @memcpy(result[0..2], "[]");
                    @memcpy(result[2..], nested_name);
                    return result;
                } else {
                    const elem_type = try goTypeForValue(allocator, first);
                    defer allocator.free(elem_type);
                    const result = try allocator.alloc(u8, 2 + elem_type.len);
                    @memcpy(result[0..2], "[]");
                    @memcpy(result[2..], elem_type);
                    return result;
                }
            } else {
                return try allocator.dupe(u8, "[]interface{}");
            }
        },
        else => return try goTypeForValue(allocator, value),
    }
}

fn goTypeForValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return switch (value) {
        .string => try allocator.dupe(u8, "string"),
        .integer => try allocator.dupe(u8, "int64"),
        .float => try allocator.dupe(u8, "float64"),
        .bool => try allocator.dupe(u8, "bool"),
        .null => try allocator.dupe(u8, "interface{}"),
        .object => try allocator.dupe(u8, "map[string]interface{}"),
        .array => try allocator.dupe(u8, "[]interface{}"),
        .number_string => try allocator.dupe(u8, "json.Number"),
    };
}

fn toPascalCase(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);

    var capitalize_next = true;
    for (input) |c| {
        if (c == '_' or c == '-' or c == ' ') {
            capitalize_next = true;
            continue;
        }
        if (capitalize_next) {
            try result.append(allocator, std.ascii.toUpper(c));
            capitalize_next = false;
        } else {
            try result.append(allocator, c);
        }
    }

    if (result.items.len == 0) {
        try result.append(allocator, 'X');
    }

    return try result.toOwnedSlice(allocator);
}

fn writeIndent(allocator: std.mem.Allocator, output: *std.ArrayList(u8), level: usize) !void {
    for (0..level) |_| {
        try output.append(allocator, '\t');
    }
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "yamlstruct",
    .description = "Generate Go struct from YAML",
    .category = .json,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_yamlstruct_out.tmp";

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

test "yamlstruct simple mapping" {
    const output = try execWithInput("name: zuxi\nversion: 1\nactive: true");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "type Root struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Name string `json:\"name\"`") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Version int64 `json:\"version\"`") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Active bool `json:\"active\"`") != null);
}

test "yamlstruct nested mapping" {
    const output = try execWithInput("server:\n  host: localhost\n  port: 8080");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "type Root struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Server Server `json:\"server\"`") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "type Server struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Host string `json:\"host\"`") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Port int64 `json:\"port\"`") != null);
}

test "yamlstruct with null and float" {
    const output = try execWithInput("data: null\nprice: 9.99");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Data interface{}") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Price float64") != null);
}

test "yamlstruct with sequence" {
    const output = try execWithInput("tags:\n  - dev\n  - prod");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Tags []string `json:\"tags\"`") != null);
}

test "yamlstruct snake_case keys" {
    const output = try execWithInput("user_name: test\ncreated_at: now");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "UserName string") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "CreatedAt string") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "`json:\"user_name\"`") != null);
}

test "yamlstruct empty input" {
    const result = execWithInput("");
    if (result) |output| {
        defer std.testing.allocator.free(output);
        // Empty YAML produces scalar comment.
        try std.testing.expect(std.mem.indexOf(u8, output, "Cannot generate struct") != null);
    } else |_| {}
}

test "yamlstruct command struct fields" {
    try std.testing.expectEqualStrings("yamlstruct", command.name);
    try std.testing.expectEqual(registry.Category.json, command.category);
}
