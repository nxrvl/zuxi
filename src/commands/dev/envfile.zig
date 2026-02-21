const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// A parsed .env entry.
const EnvEntry = struct {
    key: []const u8,
    value: []const u8,
};

/// Parse a .env file into key-value entries.
/// Handles: comments (#), empty lines, quoted values (single/double), KEY=VALUE format.
fn parseEnvFile(input: []const u8, allocator: std.mem.Allocator) ![]const EnvEntry {
    var entries = std.ArrayList(EnvEntry){};

    var start: usize = 0;
    while (start < input.len) {
        // Find end of line.
        var end = start;
        while (end < input.len and input[end] != '\n') : (end += 1) {}
        const line = if (end > start and input[end - 1] == '\r') input[start .. end - 1] else input[start..end];
        start = end + 1;

        // Trim whitespace.
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

        // Skip empty lines and comments.
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Find the = separator.
        const eq_pos = std.mem.indexOf(u8, trimmed, "=") orelse {
            entries.deinit(allocator);
            return error.InvalidInput;
        };

        const key = std.mem.trim(u8, trimmed[0..eq_pos], &std.ascii.whitespace);
        if (key.len == 0) {
            entries.deinit(allocator);
            return error.InvalidInput;
        }

        // Validate key: must be [A-Za-z_][A-Za-z0-9_]*
        if (!isValidEnvKey(key)) {
            entries.deinit(allocator);
            return error.InvalidInput;
        }

        var value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], &std.ascii.whitespace);

        // Handle quoted values.
        if (value.len >= 2) {
            if ((value[0] == '"' and value[value.len - 1] == '"') or
                (value[0] == '\'' and value[value.len - 1] == '\''))
            {
                value = value[1 .. value.len - 1];
            }
        }

        try entries.append(allocator, .{ .key = key, .value = value });
    }

    return entries.toOwnedSlice(allocator);
}

/// Check if a string is a valid env variable name.
fn isValidEnvKey(key: []const u8) bool {
    if (key.len == 0) return false;
    // First character must be a letter or underscore.
    if (!std.ascii.isAlphabetic(key[0]) and key[0] != '_') return false;
    for (key[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// Entry point for the envfile command.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    const mode: enum { validate, to_json, to_yaml } = if (subcommand) |sub| blk: {
        if (std.mem.eql(u8, sub, "validate")) break :blk .validate;
        if (std.mem.eql(u8, sub, "to-json")) break :blk .to_json;
        if (std.mem.eql(u8, sub, "to-yaml")) break :blk .to_yaml;
        const writer = ctx.stderrWriter();
        try writer.print("envfile: unknown subcommand '{s}'\n", .{sub});
        try writer.print("Available subcommands: validate, to-json, to-yaml\n", .{});
        return error.InvalidArgument;
    } else .validate; // default = validate

    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("envfile: no input provided\n", .{});
        try writer.print("Usage: zuxi envfile [validate|to-json|to-yaml] <file-content>\n", .{});
        try writer.print("       cat .env | zuxi envfile to-json\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    switch (mode) {
        .validate => {
            const entries = parseEnvFile(input.data, ctx.allocator) catch {
                try io.writeOutput(ctx, "invalid\n");
                return;
            };
            ctx.allocator.free(entries);
            try io.writeOutput(ctx, "valid\n");
        },
        .to_json => {
            const entries = parseEnvFile(input.data, ctx.allocator) catch {
                const writer = ctx.stderrWriter();
                try writer.print("envfile: invalid .env format\n", .{});
                return error.InvalidInput;
            };
            defer ctx.allocator.free(entries);

            // Build JSON output manually.
            var list = std.ArrayList(u8){};
            defer list.deinit(ctx.allocator);

            try list.appendSlice(ctx.allocator, "{\n");
            for (entries, 0..) |entry, i| {
                try list.appendSlice(ctx.allocator, "  \"");
                try appendJsonEscaped(&list, ctx.allocator, entry.key);
                try list.appendSlice(ctx.allocator, "\": \"");
                try appendJsonEscaped(&list, ctx.allocator, entry.value);
                try list.append(ctx.allocator, '"');
                if (i < entries.len - 1) {
                    try list.append(ctx.allocator, ',');
                }
                try list.append(ctx.allocator, '\n');
            }
            try list.appendSlice(ctx.allocator, "}\n");

            try io.writeOutput(ctx, list.items);
        },
        .to_yaml => {
            const entries = parseEnvFile(input.data, ctx.allocator) catch {
                const writer = ctx.stderrWriter();
                try writer.print("envfile: invalid .env format\n", .{});
                return error.InvalidInput;
            };
            defer ctx.allocator.free(entries);

            // Build YAML output.
            var list = std.ArrayList(u8){};
            defer list.deinit(ctx.allocator);

            for (entries) |entry| {
                try list.appendSlice(ctx.allocator, entry.key);
                try list.appendSlice(ctx.allocator, ": ");
                // Quote values that need quoting (contain special YAML chars or are empty).
                if (needsYamlQuoting(entry.value)) {
                    try list.append(ctx.allocator, '"');
                    try appendJsonEscaped(&list, ctx.allocator, entry.value);
                    try list.append(ctx.allocator, '"');
                } else {
                    try list.appendSlice(ctx.allocator, entry.value);
                }
                try list.append(ctx.allocator, '\n');
            }

            try io.writeOutput(ctx, list.items);
        },
    }
}

/// Check if a YAML scalar value needs quoting.
fn needsYamlQuoting(value: []const u8) bool {
    if (value.len == 0) return true;
    // Quote if contains special YAML characters.
    for (value) |c| {
        if (c == ':' or c == '#' or c == '"' or c == '\'' or c == '{' or
            c == '}' or c == '[' or c == ']' or c == ',' or c == '&' or
            c == '*' or c == '?' or c == '|' or c == '-' or c == '<' or
            c == '>' or c == '=' or c == '!' or c == '%' or c == '@' or
            c == '`' or c == '\n' or c == '\r' or c == '\t')
        {
            return true;
        }
    }
    // Quote if it looks like a boolean or null.
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false") or
        std.mem.eql(u8, value, "null") or std.mem.eql(u8, value, "yes") or
        std.mem.eql(u8, value, "no") or std.mem.eql(u8, value, "on") or
        std.mem.eql(u8, value, "off"))
    {
        return true;
    }
    return false;
}

/// Append a string with JSON escaping for special characters.
fn appendJsonEscaped(list: *std.ArrayList(u8), allocator: std.mem.Allocator, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => try list.append(allocator, c),
        }
    }
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "envfile",
    .description = "Validate and convert .env files",
    .category = .dev,
    .subcommands = &.{ "validate", "to-json", "to-yaml" },
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_envfile_out.tmp";

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

test "envfile validate valid file" {
    const output = try execWithInput("DB_HOST=localhost\nDB_PORT=5432\n", "validate");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("valid", trimmed);
}

test "envfile validate with comments and empty lines" {
    const output = try execWithInput("# comment\n\nAPP_NAME=zuxi\n", "validate");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("valid", trimmed);
}

test "envfile validate with quoted values" {
    const output = try execWithInput("KEY=\"hello world\"\nKEY2='single'\n", "validate");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("valid", trimmed);
}

test "envfile validate invalid - no equals" {
    const output = try execWithInput("INVALID_LINE\n", "validate");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("invalid", trimmed);
}

test "envfile validate invalid - empty key" {
    const output = try execWithInput("=value\n", "validate");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("invalid", trimmed);
}

test "envfile to-json basic" {
    const output = try execWithInput("HOST=localhost\nPORT=3000\n", "to-json");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"HOST\": \"localhost\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"PORT\": \"3000\"") != null);
}

test "envfile to-json with quoted value" {
    const output = try execWithInput("MSG=\"hello world\"\n", "to-json");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"MSG\": \"hello world\"") != null);
}

test "envfile to-json skips comments" {
    const output = try execWithInput("# comment\nKEY=val\n", "to-json");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "comment") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"KEY\": \"val\"") != null);
}

test "envfile to-yaml basic" {
    const output = try execWithInput("HOST=localhost\nPORT=3000\n", "to-yaml");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "HOST: localhost") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PORT: 3000") != null);
}

test "envfile to-yaml quotes special values" {
    const output = try execWithInput("DEBUG=true\nEMPTY=\n", "to-yaml");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "DEBUG: \"true\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "EMPTY: \"\"") != null);
}

test "envfile default subcommand is validate" {
    const output = try execWithInput("KEY=value\n", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("valid", trimmed);
}

test "envfile unknown subcommand" {
    const result = execWithInput("KEY=val\n", "unknown");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "envfile to-json invalid input" {
    const result = execWithInput("NOT_VALID\n", "to-json");
    try std.testing.expectError(error.InvalidInput, result);
}

test "envfile command struct fields" {
    try std.testing.expectEqualStrings("envfile", command.name);
    try std.testing.expectEqual(registry.Category.dev, command.category);
    try std.testing.expectEqual(@as(usize, 3), command.subcommands.len);
}

test "isValidEnvKey accepts valid keys" {
    try std.testing.expect(isValidEnvKey("DB_HOST"));
    try std.testing.expect(isValidEnvKey("_PRIVATE"));
    try std.testing.expect(isValidEnvKey("a"));
    try std.testing.expect(isValidEnvKey("APP_NAME_2"));
}

test "isValidEnvKey rejects invalid keys" {
    try std.testing.expect(!isValidEnvKey(""));
    try std.testing.expect(!isValidEnvKey("1ABC"));
    try std.testing.expect(!isValidEnvKey("key-name"));
    try std.testing.expect(!isValidEnvKey("key name"));
}

test "envfile handles CRLF line endings" {
    const output = try execWithInput("KEY=value\r\nOTHER=test\r\n", "validate");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("valid", trimmed);
}

test "envfile to-json escapes special chars" {
    const output = try execWithInput("MSG=hello\"world\n", "to-json");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "hello\\\"world") != null);
}
