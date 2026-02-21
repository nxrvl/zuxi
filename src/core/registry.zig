const std = @import("std");
const context = @import("context.zig");
const errors = @import("errors.zig");

/// Command category for grouping in help and TUI.
pub const Category = enum {
    json,
    encoding,
    security,
    time,
    dev,
    docs,
};

/// Format a category as a display string.
pub fn categoryName(cat: Category) []const u8 {
    return switch (cat) {
        .json => "JSON",
        .encoding => "Encoding",
        .security => "Security",
        .time => "Time",
        .dev => "Dev Tools",
        .docs => "Docs",
    };
}

/// A registered command definition.
pub const Command = struct {
    /// Primary command name (e.g., "jsonfmt", "base64").
    name: []const u8,
    /// Short description shown in help text.
    description: []const u8,
    /// Command category for grouping.
    category: Category,
    /// List of subcommands (empty slice if none).
    subcommands: []const []const u8,
    /// Execute the command with the given context and optional subcommand.
    execute: *const fn (ctx: context.Context, subcommand: ?[]const u8) anyerror!void,
};

/// Maximum number of commands the registry can hold.
const max_commands = 64;

/// Command registry that stores and retrieves registered commands.
pub const Registry = struct {
    commands: [max_commands]?Command = [_]?Command{null} ** max_commands,
    count: usize = 0,

    /// Register a command. Returns error if registry is full or name is duplicate.
    pub fn register(self: *Registry, cmd: Command) errors.ZuxiError!void {
        if (self.count >= max_commands) {
            return error.BufferTooSmall;
        }
        // Check for duplicate name.
        for (self.commands[0..self.count]) |slot| {
            if (slot) |existing| {
                if (std.mem.eql(u8, existing.name, cmd.name)) {
                    return error.InvalidArgument;
                }
            }
        }
        self.commands[self.count] = cmd;
        self.count += 1;
    }

    /// Look up a command by name. Returns null if not found.
    pub fn lookup(self: *const Registry, name: []const u8) ?Command {
        for (self.commands[0..self.count]) |slot| {
            if (slot) |cmd| {
                if (std.mem.eql(u8, cmd.name, name)) {
                    return cmd;
                }
            }
        }
        return null;
    }

    /// Return a slice of all registered commands.
    pub fn list(self: *const Registry) []const ?Command {
        return self.commands[0..self.count];
    }

    /// Get the number of registered commands.
    pub fn commandCount(self: *const Registry) usize {
        return self.count;
    }

    /// List commands filtered by category.
    pub fn listByCategory(self: *const Registry, cat: Category, buf: []Command) []Command {
        var n: usize = 0;
        for (self.commands[0..self.count]) |slot| {
            if (slot) |cmd| {
                if (cmd.category == cat and n < buf.len) {
                    buf[n] = cmd;
                    n += 1;
                }
            }
        }
        return buf[0..n];
    }
};

/// Global registry instance.
var global_registry = Registry{};

/// Get the global registry.
pub fn getGlobalRegistry() *Registry {
    return &global_registry;
}

// --- Tests ---

fn dummyExecute(_: context.Context, _: ?[]const u8) anyerror!void {}

test "Registry register and lookup" {
    var reg = Registry{};
    try reg.register(.{
        .name = "test_cmd",
        .description = "A test command",
        .category = .json,
        .subcommands = &.{},
        .execute = dummyExecute,
    });

    const found = reg.lookup("test_cmd");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("test_cmd", found.?.name);
    try std.testing.expectEqualStrings("A test command", found.?.description);
    try std.testing.expectEqual(Category.json, found.?.category);
}

test "Registry lookup returns null for unknown command" {
    var reg = Registry{};
    const found = reg.lookup("nonexistent");
    try std.testing.expect(found == null);
}

test "Registry rejects duplicate names" {
    var reg = Registry{};
    try reg.register(.{
        .name = "dup",
        .description = "first",
        .category = .dev,
        .subcommands = &.{},
        .execute = dummyExecute,
    });
    const result = reg.register(.{
        .name = "dup",
        .description = "second",
        .category = .dev,
        .subcommands = &.{},
        .execute = dummyExecute,
    });
    try std.testing.expectError(error.InvalidArgument, result);
}

test "Registry list returns all registered commands" {
    var reg = Registry{};
    try reg.register(.{
        .name = "cmd_a",
        .description = "A",
        .category = .json,
        .subcommands = &.{},
        .execute = dummyExecute,
    });
    try reg.register(.{
        .name = "cmd_b",
        .description = "B",
        .category = .encoding,
        .subcommands = &.{},
        .execute = dummyExecute,
    });
    const cmds = reg.list();
    try std.testing.expectEqual(@as(usize, 2), cmds.len);
}

test "Registry commandCount" {
    var reg = Registry{};
    try std.testing.expectEqual(@as(usize, 0), reg.commandCount());
    try reg.register(.{
        .name = "x",
        .description = "X",
        .category = .dev,
        .subcommands = &.{},
        .execute = dummyExecute,
    });
    try std.testing.expectEqual(@as(usize, 1), reg.commandCount());
}

test "Registry listByCategory filters correctly" {
    var reg = Registry{};
    try reg.register(.{
        .name = "json1",
        .description = "J1",
        .category = .json,
        .subcommands = &.{},
        .execute = dummyExecute,
    });
    try reg.register(.{
        .name = "enc1",
        .description = "E1",
        .category = .encoding,
        .subcommands = &.{},
        .execute = dummyExecute,
    });
    try reg.register(.{
        .name = "json2",
        .description = "J2",
        .category = .json,
        .subcommands = &.{},
        .execute = dummyExecute,
    });

    var buf: [8]Command = undefined;
    const json_cmds = reg.listByCategory(.json, &buf);
    try std.testing.expectEqual(@as(usize, 2), json_cmds.len);

    const enc_cmds = reg.listByCategory(.encoding, &buf);
    try std.testing.expectEqual(@as(usize, 1), enc_cmds.len);

    const sec_cmds = reg.listByCategory(.security, &buf);
    try std.testing.expectEqual(@as(usize, 0), sec_cmds.len);
}

test "categoryName returns display strings" {
    try std.testing.expectEqualStrings("JSON", categoryName(.json));
    try std.testing.expectEqualStrings("Encoding", categoryName(.encoding));
    try std.testing.expectEqualStrings("Security", categoryName(.security));
    try std.testing.expectEqualStrings("Time", categoryName(.time));
    try std.testing.expectEqualStrings("Dev Tools", categoryName(.dev));
    try std.testing.expectEqualStrings("Docs", categoryName(.docs));
}

test "Command with subcommands" {
    var reg = Registry{};
    const subs = [_][]const u8{ "encode", "decode" };
    try reg.register(.{
        .name = "base64",
        .description = "Base64 encode/decode",
        .category = .encoding,
        .subcommands = &subs,
        .execute = dummyExecute,
    });
    const cmd = reg.lookup("base64").?;
    try std.testing.expectEqual(@as(usize, 2), cmd.subcommands.len);
    try std.testing.expectEqualStrings("encode", cmd.subcommands[0]);
    try std.testing.expectEqualStrings("decode", cmd.subcommands[1]);
}
