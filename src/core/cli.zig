const std = @import("std");
const context = @import("context.zig");
const registry = @import("registry.zig");
const errors = @import("errors.zig");
const io = @import("io.zig");
const build_options = @import("build_options");

/// Result of parsing CLI arguments.
pub const ParseResult = union(enum) {
    /// Display version and exit.
    version,
    /// Display help and exit.
    help,
    /// Display help for a specific command.
    command_help: []const u8,
    /// Launch TUI mode (no arguments given).
    tui,
    /// Execute a command.
    command: CommandInvocation,
};

/// A parsed command invocation ready for execution.
pub const CommandInvocation = struct {
    /// The command name.
    command_name: []const u8,
    /// The subcommand (if any).
    subcommand: ?[]const u8,
    /// Parsed global flags.
    flags: context.Flags,
    /// Remaining positional arguments after command/subcommand/flags.
    positional_args: []const []const u8,
};

/// Parse CLI arguments into a ParseResult.
/// The `raw_args` slice should NOT include the program name (argv[0]).
/// `positional_out` is a caller-provided buffer for storing positional arguments,
/// ensuring the returned slices remain valid after this function returns.
pub fn parseArgs(raw_args: []const []const u8, positional_out: [][]const u8) errors.ZuxiError!ParseResult {
    if (raw_args.len == 0) {
        return .tui;
    }

    var flags = context.Flags{};
    var positional_count: usize = 0;
    var i: usize = 0;
    var command_name: ?[]const u8 = null;
    var subcommand: ?[]const u8 = null;

    while (i < raw_args.len) : (i += 1) {
        const arg = raw_args[i];

        if (std.mem.startsWith(u8, arg, "-")) {
            // It's a flag.
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                if (command_name) |cmd| {
                    return .{ .command_help = cmd };
                }
                return .help;
            }
            if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
                return .version;
            }
            if (std.mem.eql(u8, arg, "--no-color")) {
                flags.no_color = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
                flags.quiet = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
                i += 1;
                if (i >= raw_args.len) {
                    return error.MissingArgument;
                }
                flags.output_file = raw_args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
                i += 1;
                if (i >= raw_args.len) {
                    return error.MissingArgument;
                }
                const fmt_str = raw_args[i];
                if (std.mem.eql(u8, fmt_str, "json")) {
                    flags.format = .json;
                } else if (std.mem.eql(u8, fmt_str, "text")) {
                    flags.format = .text;
                } else {
                    return error.InvalidArgument;
                }
                continue;
            }
            // Unknown flag - treat as an error.
            return error.InvalidArgument;
        }

        // Not a flag - it's a positional argument.
        if (command_name == null) {
            command_name = arg;
        } else if (subcommand == null and !isPositionalArg(arg)) {
            subcommand = arg;
        } else {
            if (positional_count >= positional_out.len) {
                return error.BufferTooSmall;
            }
            positional_out[positional_count] = arg;
            positional_count += 1;
        }
    }

    if (command_name) |cmd| {
        return .{ .command = .{
            .command_name = cmd,
            .subcommand = subcommand,
            .flags = flags,
            .positional_args = positional_out[0..positional_count],
        } };
    }

    // Only flags, no command - treat as help.
    return .help;
}

/// Heuristic: if a string looks like a "data" argument rather than a subcommand name.
/// Subcommands are simple lowercase identifiers; anything else is positional data.
fn isPositionalArg(arg: []const u8) bool {
    if (arg.len == 0) return true;
    // If it contains spaces, slashes, dots, or starts with a digit, it's positional data.
    for (arg) |c| {
        if (c == ' ' or c == '/' or c == '\\' or c == '.' or c == '{' or c == '"') {
            return true;
        }
    }
    // If it starts with a digit, it's positional.
    if (std.ascii.isDigit(arg[0])) return true;
    return false;
}

/// Execute a parsed command invocation using the given registry.
pub fn dispatch(reg: *const registry.Registry, invocation: CommandInvocation, allocator: std.mem.Allocator) !void {
    const cmd = reg.lookup(invocation.command_name) orelse {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("zuxi: unknown command '{s}'\n", .{invocation.command_name});
        try stderr.print("Run 'zuxi --help' for usage.\n", .{});
        std.process.exit(1);
    };

    var ctx = context.Context.initDefault(allocator);
    ctx.flags = invocation.flags;
    ctx.args = invocation.positional_args;

    try cmd.execute(ctx, invocation.subcommand);
}

/// Print version string.
pub fn printVersion(writer: anytype) !void {
    const mode_str = switch (build_options.build_mode) {
        .lite => "lite",
        .full => "full",
    };
    try writer.print("zuxi v{s} ({s})\n", .{ "0.1.0", mode_str });
}

/// Print help with command listing from registry.
pub fn printHelp(writer: anytype, reg: *const registry.Registry) !void {
    try writer.print(
        \\zuxi v{s} - Offline developer toolkit
        \\
        \\Usage: zuxi <command> [subcommand] [flags]
        \\       zuxi                          (launch TUI)
        \\
        \\Global flags:
        \\  --help, -h       Show this help
        \\  --version, -v    Show version
        \\  --output <file>  Write output to file
        \\  --format <fmt>   Output format: json, text
        \\  --no-color       Disable colored output
        \\  --quiet          Suppress non-essential output
        \\
    , .{"0.1.0"});

    // Group commands by category.
    const categories = [_]registry.Category{ .json, .encoding, .security, .time, .dev, .docs };
    var any_commands = false;

    for (categories) |cat| {
        var buf: [64]registry.Command = undefined;
        const cmds = reg.listByCategory(cat, &buf);
        if (cmds.len == 0) continue;

        if (!any_commands) {
            try writer.print("Commands:\n", .{});
            any_commands = true;
        }

        try writer.print("  {s}:\n", .{registry.categoryName(cat)});
        for (cmds) |cmd| {
            try writer.print("    {s: <16}{s}\n", .{ cmd.name, cmd.description });
        }
    }

    if (!any_commands) {
        try writer.print("No commands registered yet.\n", .{});
    }
}

/// Print help for a specific command.
pub fn printCommandHelp(writer: anytype, reg: *const registry.Registry, cmd_name: []const u8) !void {
    const cmd = reg.lookup(cmd_name) orelse {
        try writer.print("zuxi: unknown command '{s}'\n", .{cmd_name});
        return;
    };

    try writer.print("{s} - {s}\n\n", .{ cmd.name, cmd.description });
    try writer.print("Category: {s}\n", .{registry.categoryName(cmd.category)});

    if (cmd.subcommands.len > 0) {
        try writer.print("\nSubcommands:\n", .{});
        for (cmd.subcommands) |sub| {
            try writer.print("  {s}\n", .{sub});
        }
    }

    try writer.print("\nUsage: zuxi {s}", .{cmd.name});
    if (cmd.subcommands.len > 0) {
        try writer.print(" <subcommand>", .{});
    }
    try writer.print(" [flags] [input]\n", .{});
}

// --- Tests ---

test "parseArgs with no args returns tui" {
    const args = [_][]const u8{};
    var pbuf: [16][]const u8 = undefined;
    const result = try parseArgs(&args, &pbuf);
    try std.testing.expect(result == .tui);
}

test "parseArgs --version" {
    const args = [_][]const u8{"--version"};
    var pbuf: [16][]const u8 = undefined;
    const result = try parseArgs(&args, &pbuf);
    try std.testing.expect(result == .version);
}

test "parseArgs -v" {
    const args = [_][]const u8{"-v"};
    var pbuf: [16][]const u8 = undefined;
    const result = try parseArgs(&args, &pbuf);
    try std.testing.expect(result == .version);
}

test "parseArgs --help" {
    const args = [_][]const u8{"--help"};
    var pbuf: [16][]const u8 = undefined;
    const result = try parseArgs(&args, &pbuf);
    try std.testing.expect(result == .help);
}

test "parseArgs -h" {
    const args = [_][]const u8{"-h"};
    var pbuf: [16][]const u8 = undefined;
    const result = try parseArgs(&args, &pbuf);
    try std.testing.expect(result == .help);
}

test "parseArgs command only" {
    const args = [_][]const u8{"jsonfmt"};
    var pbuf: [16][]const u8 = undefined;
    const result = try parseArgs(&args, &pbuf);
    switch (result) {
        .command => |inv| {
            try std.testing.expectEqualStrings("jsonfmt", inv.command_name);
            try std.testing.expect(inv.subcommand == null);
            try std.testing.expectEqual(@as(usize, 0), inv.positional_args.len);
        },
        else => return error.InvalidInput,
    }
}

test "parseArgs command with subcommand" {
    const args = [_][]const u8{ "base64", "encode" };
    var pbuf: [16][]const u8 = undefined;
    const result = try parseArgs(&args, &pbuf);
    switch (result) {
        .command => |inv| {
            try std.testing.expectEqualStrings("base64", inv.command_name);
            try std.testing.expectEqualStrings("encode", inv.subcommand.?);
        },
        else => return error.InvalidInput,
    }
}

test "parseArgs command with subcommand and positional arg" {
    const args = [_][]const u8{ "base64", "encode", "hello" };
    var pbuf: [16][]const u8 = undefined;
    const result = try parseArgs(&args, &pbuf);
    switch (result) {
        .command => |inv| {
            try std.testing.expectEqualStrings("base64", inv.command_name);
            try std.testing.expectEqualStrings("encode", inv.subcommand.?);
            try std.testing.expectEqual(@as(usize, 1), inv.positional_args.len);
            try std.testing.expectEqualStrings("hello", inv.positional_args[0]);
        },
        else => return error.InvalidInput,
    }
}

test "parseArgs global flags --no-color --quiet" {
    const args = [_][]const u8{ "hash", "sha256", "--no-color", "--quiet" };
    var pbuf: [16][]const u8 = undefined;
    const result = try parseArgs(&args, &pbuf);
    switch (result) {
        .command => |inv| {
            try std.testing.expect(inv.flags.no_color);
            try std.testing.expect(inv.flags.quiet);
        },
        else => return error.InvalidInput,
    }
}

test "parseArgs --output flag" {
    const args = [_][]const u8{ "jsonfmt", "--output", "out.json" };
    var pbuf: [16][]const u8 = undefined;
    const result = try parseArgs(&args, &pbuf);
    switch (result) {
        .command => |inv| {
            try std.testing.expectEqualStrings("out.json", inv.flags.output_file.?);
        },
        else => return error.InvalidInput,
    }
}

test "parseArgs --format json" {
    const args = [_][]const u8{ "jsonfmt", "--format", "json" };
    var pbuf: [16][]const u8 = undefined;
    const result = try parseArgs(&args, &pbuf);
    switch (result) {
        .command => |inv| {
            try std.testing.expectEqual(context.OutputFormat.json, inv.flags.format);
        },
        else => return error.InvalidInput,
    }
}

test "parseArgs --format text" {
    const args = [_][]const u8{ "jsonfmt", "--format", "text" };
    var pbuf: [16][]const u8 = undefined;
    const result = try parseArgs(&args, &pbuf);
    switch (result) {
        .command => |inv| {
            try std.testing.expectEqual(context.OutputFormat.text, inv.flags.format);
        },
        else => return error.InvalidInput,
    }
}

test "parseArgs --format invalid value" {
    const args = [_][]const u8{ "jsonfmt", "--format", "xml" };
    var pbuf: [16][]const u8 = undefined;
    const result = parseArgs(&args, &pbuf);
    try std.testing.expectError(error.InvalidArgument, result);
}

test "parseArgs --output missing value" {
    const args = [_][]const u8{ "jsonfmt", "--output" };
    var pbuf: [16][]const u8 = undefined;
    const result = parseArgs(&args, &pbuf);
    try std.testing.expectError(error.MissingArgument, result);
}

test "parseArgs --format missing value" {
    const args = [_][]const u8{ "jsonfmt", "--format" };
    var pbuf: [16][]const u8 = undefined;
    const result = parseArgs(&args, &pbuf);
    try std.testing.expectError(error.MissingArgument, result);
}

test "parseArgs command --help shows command help" {
    const args = [_][]const u8{ "jsonfmt", "--help" };
    var pbuf: [16][]const u8 = undefined;
    const result = try parseArgs(&args, &pbuf);
    switch (result) {
        .command_help => |name| {
            try std.testing.expectEqualStrings("jsonfmt", name);
        },
        else => return error.InvalidInput,
    }
}

test "parseArgs flags before command" {
    const args = [_][]const u8{ "--no-color", "hash", "sha256", "test" };
    var pbuf: [16][]const u8 = undefined;
    const result = try parseArgs(&args, &pbuf);
    switch (result) {
        .command => |inv| {
            try std.testing.expect(inv.flags.no_color);
            try std.testing.expectEqualStrings("hash", inv.command_name);
            try std.testing.expectEqualStrings("sha256", inv.subcommand.?);
            try std.testing.expectEqual(@as(usize, 1), inv.positional_args.len);
        },
        else => return error.InvalidInput,
    }
}

test "parseArgs unknown flag" {
    const args = [_][]const u8{ "--unknown" };
    var pbuf: [16][]const u8 = undefined;
    const result = parseArgs(&args, &pbuf);
    try std.testing.expectError(error.InvalidArgument, result);
}

test "printVersion writes version string" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try printVersion(fbs.writer());
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.startsWith(u8, output, "zuxi v0.1.0"));
}

test "printHelp with empty registry" {
    var reg = registry.Registry{};
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try printHelp(fbs.writer(), &reg);
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Usage:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "No commands registered yet.") != null);
}

test "printHelp with registered commands" {
    var reg = registry.Registry{};
    const dummy_fn = struct {
        fn exec(_: context.Context, _: ?[]const u8) anyerror!void {}
    }.exec;
    try reg.register(.{
        .name = "jsonfmt",
        .description = "Format JSON",
        .category = .json,
        .subcommands = &.{},
        .execute = dummy_fn,
    });
    try reg.register(.{
        .name = "base64",
        .description = "Base64 encode/decode",
        .category = .encoding,
        .subcommands = &.{},
        .execute = dummy_fn,
    });

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try printHelp(fbs.writer(), &reg);
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Commands:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "jsonfmt") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "base64") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "JSON:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Encoding:") != null);
}

test "printCommandHelp for known command" {
    var reg = registry.Registry{};
    const subs = [_][]const u8{ "encode", "decode" };
    const dummy_fn = struct {
        fn exec(_: context.Context, _: ?[]const u8) anyerror!void {}
    }.exec;
    try reg.register(.{
        .name = "base64",
        .description = "Base64 encode/decode",
        .category = .encoding,
        .subcommands = &subs,
        .execute = dummy_fn,
    });

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try printCommandHelp(fbs.writer(), &reg, "base64");
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "base64") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Base64 encode/decode") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "encode") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "decode") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Subcommands:") != null);
}

test "printCommandHelp for unknown command" {
    var reg = registry.Registry{};
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try printCommandHelp(fbs.writer(), &reg, "nonexistent");
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "unknown command") != null);
}

test "isPositionalArg detects data-like strings" {
    try std.testing.expect(isPositionalArg("123"));
    try std.testing.expect(isPositionalArg("/path/to/file"));
    try std.testing.expect(isPositionalArg("{\"key\":1}"));
    try std.testing.expect(isPositionalArg("file.txt"));
    try std.testing.expect(!isPositionalArg("encode"));
    try std.testing.expect(!isPositionalArg("sha256"));
}
