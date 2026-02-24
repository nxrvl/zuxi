const std = @import("std");
const context = @import("context.zig");
const registry = @import("registry.zig");
const errors = @import("errors.zig");
const io = @import("io.zig");
const build_options = @import("build_options");

/// Shell type for completions generation.
pub const Shell = enum { fish, bash, zsh };

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
    /// Generate shell completions.
    completions: Shell,
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
            // Unknown flag: if we have a command, pass through as positional
            // arg so commands can handle their own flags (e.g., http --header).
            if (command_name != null) {
                if (positional_count >= positional_out.len) {
                    return error.BufferTooSmall;
                }
                positional_out[positional_count] = arg;
                positional_count += 1;
                continue;
            }
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
        // Handle "completions" as a special meta-command.
        if (std.mem.eql(u8, cmd, "completions")) {
            const shell = parseShell(subcommand);
            return .{ .completions = shell };
        }

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

/// Compute Levenshtein edit distance between two strings, capped at `limit + 1`.
/// Returns early once the minimum possible distance exceeds the limit.
fn editDistance(a: []const u8, b: []const u8, limit: usize) usize {
    if (a.len == 0) return @min(b.len, limit + 1);
    if (b.len == 0) return @min(a.len, limit + 1);
    // Lengths differ by more than limit — no need to compute.
    if (a.len > b.len + limit or b.len > a.len + limit) return limit + 1;

    var prev_row: [64]usize = undefined;
    if (b.len >= prev_row.len) return limit + 1;
    for (0..b.len + 1) |j| prev_row[j] = j;

    for (a, 0..) |ca, i| {
        var prev = prev_row[0];
        prev_row[0] = i + 1;
        var row_min: usize = prev_row[0];
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            const next = @min(@min(prev_row[j + 1] + 1, prev_row[j] + 1), prev + cost);
            prev = prev_row[j + 1];
            prev_row[j + 1] = next;
            row_min = @min(row_min, next);
        }
        // Early exit: if the entire row exceeds the limit, the final result will too.
        if (row_min > limit) return limit + 1;
    }
    return prev_row[b.len];
}

/// Execute a parsed command invocation using the given registry.
pub fn dispatch(reg: *const registry.Registry, invocation: CommandInvocation, allocator: std.mem.Allocator) !void {
    const cmd = reg.lookup(invocation.command_name) orelse {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("zuxi: unknown command '{s}'\n", .{invocation.command_name});
        try stderr.print("Run 'zuxi --help' for usage.\n", .{});
        std.process.exit(1);
    };

    // If the parsed "subcommand" isn't actually a valid subcommand for this command,
    // treat it as the first positional argument instead (e.g. `zuxi base64 hello`
    // where "hello" is data, not a subcommand).
    var actual_sub = invocation.subcommand;
    var args_to_use = invocation.positional_args;
    var merged_args_buf: [129][]const u8 = undefined;
    if (actual_sub) |sub| {
        var is_valid = false;
        for (cmd.subcommands) |valid_sub| {
            if (std.mem.eql(u8, sub, valid_sub)) {
                is_valid = true;
                break;
            }
        }
        if (!is_valid) {
            // Check if the word is close to a valid subcommand (likely a typo).
            // Edit distance <= 2 catches common typos like "unixx" for "unix"
            // or "decod" for "decode", while letting unrelated words like "test"
            // pass through as data input for commands like `zuxi hash test`.
            var closest_dist: usize = std.math.maxInt(usize);
            var closest_sub: ?[]const u8 = null;
            for (cmd.subcommands) |valid_sub| {
                const dist = editDistance(sub, valid_sub, 2);
                if (dist < closest_dist) {
                    closest_dist = dist;
                    closest_sub = valid_sub;
                }
            }

            const is_likely_typo = closest_dist <= 2;

            if (invocation.positional_args.len > 0 or is_likely_typo) {
                // Either extra positional args exist (clearly intended as subcommand)
                // or the word is close to a valid subcommand (likely a typo).
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("zuxi: '{s}' is not a valid subcommand of '{s}'", .{ sub, cmd.name }) catch {};
                if (is_likely_typo) {
                    if (closest_sub) |cs| {
                        stderr.print(" (did you mean '{s}'?)", .{cs}) catch {};
                    }
                }
                stderr.print("\n", .{}) catch {};
                if (cmd.subcommands.len > 0 and !is_likely_typo) {
                    stderr.print("Available subcommands:", .{}) catch {};
                    for (cmd.subcommands) |valid_sub| {
                        stderr.print(" {s}", .{valid_sub}) catch {};
                    }
                    stderr.print("\n", .{}) catch {};
                }
                stderr.print("Run 'zuxi {s} --help' for usage.\n", .{cmd.name}) catch {};
                std.process.exit(1);
            }
            // No extra positional args and not a close match to any subcommand —
            // treat unknown word as data input.
            // E.g. `zuxi hash test` → hash "test" with default algorithm.
            merged_args_buf[0] = sub;
            args_to_use = merged_args_buf[0..1];
            actual_sub = null;
        }
    }

    var ctx = context.Context.initDefault(allocator);
    ctx.flags = invocation.flags;
    ctx.args = args_to_use;

    try cmd.execute(ctx, actual_sub);
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

/// Parse a shell name from the completions subcommand.
/// Defaults to detecting from $SHELL env var, falls back to bash.
fn parseShell(subcommand: ?[]const u8) Shell {
    if (subcommand) |s| {
        if (std.mem.eql(u8, s, "fish")) return .fish;
        if (std.mem.eql(u8, s, "bash")) return .bash;
        if (std.mem.eql(u8, s, "zsh")) return .zsh;
    }
    // Auto-detect from $SHELL.
    if (std.posix.getenv("SHELL")) |shell_path| {
        if (std.mem.endsWith(u8, shell_path, "fish")) return .fish;
        if (std.mem.endsWith(u8, shell_path, "zsh")) return .zsh;
    }
    return .bash;
}

/// Generate shell completions from the registry and write to stdout.
pub fn printCompletions(writer: anytype, reg: *const registry.Registry, shell: Shell) !void {
    switch (shell) {
        .fish => try printFishCompletions(writer, reg),
        .bash => try printBashCompletions(writer, reg),
        .zsh => try printZshCompletions(writer, reg),
    }
}

fn printFishCompletions(w: anytype, reg: *const registry.Registry) !void {
    try w.print("# Completions for zuxi (auto-generated)\n", .{});
    try w.print("# Install: zuxi completions fish > ~/.config/fish/completions/zuxi.fish\n\n", .{});

    // Global flags.
    try w.print("complete -c zuxi -l help -s h -d 'Show help'\n", .{});
    try w.print("complete -c zuxi -l version -s v -d 'Show version'\n", .{});
    try w.print("complete -c zuxi -l output -s o -r -d 'Write output to file'\n", .{});
    try w.print("complete -c zuxi -l format -s f -r -a 'json text' -d 'Output format'\n", .{});
    try w.print("complete -c zuxi -l no-color -d 'Disable colored output'\n", .{});
    try w.print("complete -c zuxi -l quiet -s q -d 'Suppress non-essential output'\n", .{});
    try w.print("\n", .{});

    // "completions" meta-command.
    try w.print("complete -c zuxi -n '__fish_use_subcommand' -a 'completions' -d 'Generate shell completions'\n", .{});
    try w.print("complete -c zuxi -n '__fish_seen_subcommand_from completions' -a 'fish bash zsh'\n", .{});

    // Commands + subcommands.
    for (reg.list()) |slot| {
        const cmd = slot orelse continue;
        try w.print("complete -c zuxi -n '__fish_use_subcommand' -a '{s}' -d '{s}'\n", .{ cmd.name, cmd.description });
        if (cmd.subcommands.len > 0) {
            for (cmd.subcommands) |sub| {
                try w.print("complete -c zuxi -n '__fish_seen_subcommand_from {s}' -a '{s}'\n", .{ cmd.name, sub });
            }
        }
    }
}

fn printBashCompletions(w: anytype, reg: *const registry.Registry) !void {
    try w.print("# Completions for zuxi (auto-generated)\n", .{});
    try w.print("# Install: zuxi completions bash > /etc/bash_completion.d/zuxi\n", .{});
    try w.print("#      or: zuxi completions bash >> ~/.bashrc\n\n", .{});

    try w.print("_zuxi() {{\n", .{});
    try w.print("    local cur prev\n", .{});
    try w.print("    cur=\"${{COMP_WORDS[COMP_CWORD]}}\"\n", .{});
    try w.print("    prev=\"${{COMP_WORDS[COMP_CWORD-1]}}\"\n\n", .{});

    try w.print("    if [ \"$COMP_CWORD\" -eq 1 ]; then\n", .{});
    try w.print("        COMPREPLY=($(compgen -W \"", .{});
    // List all commands.
    var first = true;
    for (reg.list()) |slot| {
        const cmd = slot orelse continue;
        if (!first) try w.print(" ", .{});
        try w.print("{s}", .{cmd.name});
        first = false;
    }
    try w.print(" completions\" -- \"$cur\"))\n", .{});
    try w.print("        return\n", .{});
    try w.print("    fi\n\n", .{});

    try w.print("    case \"${{COMP_WORDS[1]}}\" in\n", .{});
    for (reg.list()) |slot| {
        const cmd = slot orelse continue;
        if (cmd.subcommands.len > 0) {
            try w.print("        {s}) COMPREPLY=($(compgen -W \"", .{cmd.name});
            for (cmd.subcommands, 0..) |sub, si| {
                if (si > 0) try w.print(" ", .{});
                try w.print("{s}", .{sub});
            }
            try w.print("\" -- \"$cur\")) ;;\n", .{});
        }
    }
    try w.print("        completions) COMPREPLY=($(compgen -W \"fish bash zsh\" -- \"$cur\")) ;;\n", .{});
    try w.print("    esac\n", .{});
    try w.print("}}\n\n", .{});
    try w.print("complete -F _zuxi zuxi\n", .{});
}

fn printZshCompletions(w: anytype, reg: *const registry.Registry) !void {
    try w.print("#compdef zuxi\n", .{});
    try w.print("# Completions for zuxi (auto-generated)\n", .{});
    try w.print("# Install: zuxi completions zsh > ~/.zsh/completions/_zuxi\n", .{});
    try w.print("#   (ensure ~/.zsh/completions is in $fpath)\n\n", .{});

    try w.print("_zuxi() {{\n", .{});
    try w.print("    local -a commands\n", .{});
    try w.print("    commands=(\n", .{});
    for (reg.list()) |slot| {
        const cmd = slot orelse continue;
        try w.print("        '{s}:{s}'\n", .{ cmd.name, cmd.description });
    }
    try w.print("        'completions:Generate shell completions'\n", .{});
    try w.print("    )\n\n", .{});

    try w.print("    _arguments -C \\\n", .{});
    try w.print("        '--help[Show help]' \\\n", .{});
    try w.print("        '--version[Show version]' \\\n", .{});
    try w.print("        '--no-color[Disable colored output]' \\\n", .{});
    try w.print("        '--quiet[Suppress non-essential output]' \\\n", .{});
    try w.print("        '--output[Write output to file]:file:_files' \\\n", .{});
    try w.print("        '--format[Output format]:format:(json text)' \\\n", .{});
    try w.print("        '1:command:->cmds' \\\n", .{});
    try w.print("        '*::arg:->args'\n\n", .{});

    try w.print("    case $state in\n", .{});
    try w.print("    cmds)\n", .{});
    try w.print("        _describe 'command' commands\n", .{});
    try w.print("        ;;\n", .{});
    try w.print("    args)\n", .{});
    try w.print("        case ${{words[1]}} in\n", .{});
    for (reg.list()) |slot| {
        const cmd = slot orelse continue;
        if (cmd.subcommands.len > 0) {
            try w.print("            {s}) compadd", .{cmd.name});
            for (cmd.subcommands) |sub| {
                try w.print(" {s}", .{sub});
            }
            try w.print(" ;;\n", .{});
        }
    }
    try w.print("            completions) compadd fish bash zsh ;;\n", .{});
    try w.print("        esac\n", .{});
    try w.print("        ;;\n", .{});
    try w.print("    esac\n", .{});
    try w.print("}}\n\n", .{});
    try w.print("_zuxi\n", .{});
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

test "editDistance identical strings" {
    try std.testing.expectEqual(@as(usize, 0), editDistance("unix", "unix", 2));
    try std.testing.expectEqual(@as(usize, 0), editDistance("", "", 2));
}

test "editDistance single character changes" {
    // Substitution
    try std.testing.expectEqual(@as(usize, 1), editDistance("unix", "unax", 2));
    // Insertion
    try std.testing.expectEqual(@as(usize, 1), editDistance("decod", "decode", 2));
    // Deletion
    try std.testing.expectEqual(@as(usize, 1), editDistance("decode", "decod", 2));
    // Extra character
    try std.testing.expectEqual(@as(usize, 1), editDistance("unixx", "unix", 2));
}

test "editDistance above limit returns limit + 1" {
    // "test" vs "sha256" — very different
    try std.testing.expect(editDistance("test", "sha256", 2) > 2);
    // "test" vs "md5" — different enough
    try std.testing.expect(editDistance("test", "md5", 2) > 2);
    // "hello" vs "encode" — different
    try std.testing.expect(editDistance("hello", "encode", 2) > 2);
}

test "editDistance catches common typos" {
    // "unixx" is 1 edit from "unix"
    try std.testing.expect(editDistance("unixx", "unix", 2) <= 2);
    // "decod" is 1 edit from "decode"
    try std.testing.expect(editDistance("decod", "decode", 2) <= 2);
    // "sha254" is 1 edit from "sha256"
    try std.testing.expect(editDistance("sha254", "sha256", 2) <= 2);
    // "encde" is 1 edit from "encode"
    try std.testing.expect(editDistance("encde", "encode", 2) <= 2);
}

test "editDistance empty strings" {
    try std.testing.expectEqual(@as(usize, 3), editDistance("", "abc", 5));
    try std.testing.expectEqual(@as(usize, 3), editDistance("abc", "", 5));
}

test "parseArgs completions fish" {
    const args = [_][]const u8{ "completions", "fish" };
    var pbuf: [16][]const u8 = undefined;
    const result = try parseArgs(&args, &pbuf);
    switch (result) {
        .completions => |shell| try std.testing.expectEqual(Shell.fish, shell),
        else => return error.InvalidInput,
    }
}

test "parseArgs completions bash" {
    const args = [_][]const u8{ "completions", "bash" };
    var pbuf: [16][]const u8 = undefined;
    const result = try parseArgs(&args, &pbuf);
    switch (result) {
        .completions => |shell| try std.testing.expectEqual(Shell.bash, shell),
        else => return error.InvalidInput,
    }
}

test "parseArgs completions zsh" {
    const args = [_][]const u8{ "completions", "zsh" };
    var pbuf: [16][]const u8 = undefined;
    const result = try parseArgs(&args, &pbuf);
    switch (result) {
        .completions => |shell| try std.testing.expectEqual(Shell.zsh, shell),
        else => return error.InvalidInput,
    }
}

test "parseArgs completions without shell auto-detects" {
    const args = [_][]const u8{"completions"};
    var pbuf: [16][]const u8 = undefined;
    const result = try parseArgs(&args, &pbuf);
    // Should return completions (auto-detected shell).
    switch (result) {
        .completions => {},
        else => return error.InvalidInput,
    }
}

test "printCompletions fish generates valid output" {
    var reg = registry.Registry{};
    const dummy_fn = struct {
        fn exec(_: context.Context, _: ?[]const u8) anyerror!void {}
    }.exec;
    try reg.register(.{
        .name = "jwt",
        .description = "JWT tools",
        .category = .security,
        .subcommands = &.{ "decode", "generate" },
        .execute = dummy_fn,
    });
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try printCompletions(fbs.writer(), &reg, .fish);
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "complete -c zuxi") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "'jwt'") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "'decode'") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "'generate'") != null);
}

test "printCompletions bash generates valid output" {
    var reg = registry.Registry{};
    const dummy_fn = struct {
        fn exec(_: context.Context, _: ?[]const u8) anyerror!void {}
    }.exec;
    try reg.register(.{
        .name = "hash",
        .description = "Hash tools",
        .category = .security,
        .subcommands = &.{ "sha256", "md5" },
        .execute = dummy_fn,
    });
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try printCompletions(fbs.writer(), &reg, .bash);
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "_zuxi()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "complete -F _zuxi zuxi") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hash") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "sha256 md5") != null);
}

test "printCompletions zsh generates valid output" {
    var reg = registry.Registry{};
    const dummy_fn = struct {
        fn exec(_: context.Context, _: ?[]const u8) anyerror!void {}
    }.exec;
    try reg.register(.{
        .name = "base64",
        .description = "Base64 encode/decode",
        .category = .encoding,
        .subcommands = &.{ "encode", "decode" },
        .execute = dummy_fn,
    });
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try printCompletions(fbs.writer(), &reg, .zsh);
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "#compdef zuxi") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "'base64:Base64 encode/decode'") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "encode") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "decode") != null);
}
