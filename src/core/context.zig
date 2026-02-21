const std = @import("std");
const errors = @import("errors.zig");

/// Output format for command results.
pub const OutputFormat = enum {
    text,
    json,
};

/// Global flags parsed from CLI arguments.
pub const Flags = struct {
    /// Output format (--format json|text).
    format: OutputFormat = .text,
    /// Disable colored output (--no-color).
    no_color: bool = false,
    /// Suppress non-essential output (--quiet).
    quiet: bool = false,
    /// Output file path (--output <file>), null means stdout.
    output_file: ?[]const u8 = null,
};

/// Execution context passed to every command.
/// Carries I/O handles, parsed flags, allocator, and positional arguments.
pub const Context = struct {
    /// Allocator for dynamic allocations during command execution.
    allocator: std.mem.Allocator,
    /// Standard input file handle.
    stdin: std.fs.File,
    /// Standard output file handle (or output file if --output is set).
    stdout: std.fs.File,
    /// Standard error file handle.
    stderr: std.fs.File,
    /// Parsed global flags.
    flags: Flags,
    /// Positional arguments remaining after command/subcommand/flags are parsed.
    args: []const []const u8,

    /// Create a default context using real stdio handles.
    pub fn initDefault(allocator: std.mem.Allocator) Context {
        return .{
            .allocator = allocator,
            .stdin = std.fs.File.stdin(),
            .stdout = std.fs.File.stdout(),
            .stderr = std.fs.File.stderr(),
            .flags = .{},
            .args = &.{},
        };
    }

    /// Get a deprecated writer for stdout (compatible with print()).
    pub fn stdoutWriter(self: Context) std.fs.File.DeprecatedWriter {
        return self.stdout.deprecatedWriter();
    }

    /// Get a deprecated writer for stderr (compatible with print()).
    pub fn stderrWriter(self: Context) std.fs.File.DeprecatedWriter {
        return self.stderr.deprecatedWriter();
    }

    /// Print an error message to stderr.
    pub fn printErr(self: Context, err: errors.ZuxiError, detail: ?[]const u8) !void {
        try errors.printError(self.stderrWriter(), err, detail);
    }
};

// --- Tests ---

test "Flags has sensible defaults" {
    const flags = Flags{};
    try std.testing.expectEqual(OutputFormat.text, flags.format);
    try std.testing.expect(!flags.no_color);
    try std.testing.expect(!flags.quiet);
    try std.testing.expect(flags.output_file == null);
}

test "Context initDefault creates valid context" {
    const ctx = Context.initDefault(std.testing.allocator);
    try std.testing.expectEqual(OutputFormat.text, ctx.flags.format);
    try std.testing.expect(!ctx.flags.no_color);
    try std.testing.expect(!ctx.flags.quiet);
    try std.testing.expect(ctx.flags.output_file == null);
    try std.testing.expectEqual(@as(usize, 0), ctx.args.len);
}

test "Context with custom flags" {
    var ctx = Context.initDefault(std.testing.allocator);
    ctx.flags = .{
        .format = .json,
        .no_color = true,
        .quiet = true,
        .output_file = "out.txt",
    };
    try std.testing.expectEqual(OutputFormat.json, ctx.flags.format);
    try std.testing.expect(ctx.flags.no_color);
    try std.testing.expect(ctx.flags.quiet);
    try std.testing.expectEqualStrings("out.txt", ctx.flags.output_file.?);
}

test "Context stdoutWriter produces output" {
    // We can't easily redirect real stdout in tests, but we can verify
    // the writer type is correct by checking it compiles and returns.
    const ctx = Context.initDefault(std.testing.allocator);
    const writer = ctx.stdoutWriter();
    // Just verify we got a valid writer (type check at comptime).
    _ = writer;
}

test "Context with positional args" {
    const arg_list = [_][]const u8{ "hello", "world" };
    var ctx = Context.initDefault(std.testing.allocator);
    ctx.args = &arg_list;
    try std.testing.expectEqual(@as(usize, 2), ctx.args.len);
    try std.testing.expectEqualStrings("hello", ctx.args[0]);
    try std.testing.expectEqualStrings("world", ctx.args[1]);
}
