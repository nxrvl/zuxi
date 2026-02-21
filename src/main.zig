const std = @import("std");
const build_options = @import("build_options");

pub const version = "0.1.0";
pub const app_name = "zuxi";

pub fn main() !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    var args = try std.process.ArgIterator.initWithAllocator(std.heap.page_allocator);
    defer args.deinit();

    // Skip the program name.
    _ = args.skip();

    const first_arg = args.next();

    if (first_arg) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try printVersion(stdout);
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp(stdout);
            return;
        }
        // Future: dispatch to command registry
        try stdout.print("zuxi: unknown command '{s}'\n", .{arg});
        try stdout.print("Run 'zuxi --help' for usage.\n", .{});
        std.process.exit(1);
    } else {
        // No arguments: will launch TUI in the future.
        try printVersion(stdout);
        try stdout.print("TUI mode coming soon. Use 'zuxi --help' for CLI usage.\n", .{});
    }
}

pub fn printVersion(writer: anytype) !void {
    const mode_str = switch (build_options.build_mode) {
        .lite => "lite",
        .full => "full",
    };
    try writer.print("{s} v{s} ({s})\n", .{ app_name, version, mode_str });
}

pub fn printHelp(writer: anytype) !void {
    try writer.print(
        \\{s} v{s} - Offline developer toolkit
        \\
        \\Usage: {s} <command> [subcommand] [flags]
        \\       {s}                          (launch TUI)
        \\
        \\Global flags:
        \\  --help, -h       Show this help
        \\  --version, -v    Show version
        \\  --output <file>  Write output to file
        \\  --format <fmt>   Output format: json, text
        \\  --no-color       Disable colored output
        \\  --quiet          Suppress non-essential output
        \\
        \\Commands will be available in future versions.
        \\
    , .{ app_name, version, app_name, app_name });
}

// --- Tests ---

test "version string is set" {
    try std.testing.expect(version.len > 0);
    try std.testing.expectEqualStrings("0.1.0", version);
}

test "app name is zuxi" {
    try std.testing.expectEqualStrings("zuxi", app_name);
}

test "printVersion writes correct output" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try printVersion(fbs.writer());
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.startsWith(u8, output, "zuxi v0.1.0"));
    try std.testing.expect(std.mem.indexOf(u8, output, "(full)") != null or
        std.mem.indexOf(u8, output, "(lite)") != null);
}

test "printHelp includes usage info" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try printHelp(fbs.writer());
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Usage:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--help") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--version") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--output") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--format") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--no-color") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--quiet") != null);
}

test "build mode option exists" {
    const mode = build_options.build_mode;
    try std.testing.expect(mode == .lite or mode == .full);
}
