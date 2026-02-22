const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// Entry point for the jsonstruct command.
pub fn execute(ctx: context.Context, _: ?[]const u8) anyerror!void {
    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("jsonstruct: no input provided\n", .{});
        try writer.print("Usage: zuxi jsonstruct <json>\n", .{});
        try writer.print("       echo '{{...}}' | zuxi jsonstruct\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    // Parse the JSON.
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, input.data, .{}) catch {
        const writer = ctx.stderrWriter();
        try writer.print("jsonstruct: invalid JSON input\n", .{});
        return error.FormatError;
    };
    defer parsed.deinit();

    // Generate Go struct.
    var output = std.ArrayList(u8){};
    defer output.deinit(ctx.allocator);

    try generateGoStruct(ctx.allocator, &output, "Root", parsed.value, 0);

    try output.append(ctx.allocator, '\n');
    try io.writeOutput(ctx, output.items);
}

/// Generate a Go struct definition from a JSON value.
fn generateGoStruct(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    struct_name: []const u8,
    value: std.json.Value,
    indent_level: usize,
) !void {
    switch (value) {
        .object => |obj| {
            // Collect nested struct definitions.
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

                // PascalCase field name.
                const pascal_name = try toPascalCase(allocator, key);
                defer allocator.free(pascal_name);
                try output.appendSlice(allocator, pascal_name);
                try output.append(allocator, ' ');

                // Determine Go type.
                const go_type = try inferGoType(allocator, key, val, &nested);
                defer allocator.free(go_type);
                try output.appendSlice(allocator, go_type);

                // JSON tag.
                try output.appendSlice(allocator, " `json:\"");
                try output.appendSlice(allocator, key);
                try output.appendSlice(allocator, "\"`\n");
            }

            try writeIndent(allocator, output, indent_level);
            try output.append(allocator, '}');
            try output.append(allocator, '\n');

            // Write nested struct definitions.
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
                    // Array of primitives - nothing to generate.
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
            // Scalar at root - nothing meaningful to generate.
            try output.appendSlice(allocator, "// Cannot generate struct from scalar value\n");
        },
    }
}

const NestedStruct = struct {
    name: []const u8,
    value: std.json.Value,
};

/// Infer the Go type for a JSON value. For objects, registers a nested struct.
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

/// Get the Go type for a primitive JSON value.
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

/// Convert a snake_case or camelCase string to PascalCase.
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
    .name = "jsonstruct",
    .description = "Generate Go struct from JSON",
    .category = .json,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_jsonstruct_out.tmp";

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

test "jsonstruct simple object" {
    const output = try execWithInput("{\"name\": \"zuxi\", \"version\": 1}");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "type Root struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Name string `json:\"name\"`") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Version int64 `json:\"version\"`") != null);
}

test "jsonstruct with boolean and null" {
    const output = try execWithInput("{\"active\": true, \"data\": null}");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Active bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Data interface{}") != null);
}

test "jsonstruct with float" {
    const output = try execWithInput("{\"price\": 9.99}");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Price float64") != null);
}

test "jsonstruct nested object" {
    const output = try execWithInput("{\"config\": {\"debug\": true}}");
    defer std.testing.allocator.free(output);
    // Root struct should reference Config type.
    try std.testing.expect(std.mem.indexOf(u8, output, "Config Config") != null);
    // Nested struct should be defined.
    try std.testing.expect(std.mem.indexOf(u8, output, "type Config struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Debug bool") != null);
}

test "jsonstruct array of primitives" {
    const output = try execWithInput("{\"tags\": [\"a\", \"b\"]}");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Tags []string") != null);
}

test "jsonstruct array of objects" {
    const output = try execWithInput("{\"items\": [{\"id\": 1}]}");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Items []Items") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "type Items struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Id int64") != null);
}

test "jsonstruct snake_case to PascalCase" {
    const output = try execWithInput("{\"user_name\": \"test\", \"created_at\": \"now\"}");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "UserName string") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "CreatedAt string") != null);
    // JSON tags should preserve original names.
    try std.testing.expect(std.mem.indexOf(u8, output, "`json:\"user_name\"`") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "`json:\"created_at\"`") != null);
}

test "jsonstruct invalid JSON" {
    const result = execWithInput("not json");
    try std.testing.expectError(error.FormatError, result);
}

test "jsonstruct empty input gives error" {
    const result = execWithInput("");
    try std.testing.expectError(error.FormatError, result);
}

test "jsonstruct empty object" {
    const output = try execWithInput("{}");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "type Root struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "}") != null);
}

test "jsonstruct command struct fields" {
    try std.testing.expectEqualStrings("jsonstruct", command.name);
    try std.testing.expectEqual(registry.Category.json, command.category);
}

test "toPascalCase basic" {
    const allocator = std.testing.allocator;
    const result = try toPascalCase(allocator, "hello_world");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("HelloWorld", result);
}

test "toPascalCase already pascal" {
    const allocator = std.testing.allocator;
    const result = try toPascalCase(allocator, "Name");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Name", result);
}

test "toPascalCase single word" {
    const allocator = std.testing.allocator;
    const result = try toPascalCase(allocator, "name");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Name", result);
}

test "toPascalCase with hyphens" {
    const allocator = std.testing.allocator;
    const result = try toPascalCase(allocator, "my-field");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("MyField", result);
}
