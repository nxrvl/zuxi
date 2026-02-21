const std = @import("std");
const build_options = @import("build_options");
const cli = @import("core/cli.zig");
const registry = @import("core/registry.zig");
const context = @import("core/context.zig");
const errors = @import("core/errors.zig");
const tui = @import("core/tui.zig");
const jsonfmt = @import("commands/json/jsonfmt.zig");
const base64_cmd = @import("commands/encoding/base64.zig");
const strcase_cmd = @import("commands/encoding/strcase.zig");
const hash_cmd = @import("commands/security/hash.zig");
const jwt_cmd = @import("commands/security/jwt.zig");
const time_cmd = @import("commands/time/time.zig");
const uuid_cmd = @import("commands/dev/uuid.zig");
const http_cmd = @import("commands/dev/http.zig");
const count_cmd = @import("commands/encoding/count.zig");
const slug_cmd = @import("commands/encoding/slug.zig");
const urlencode_cmd = @import("commands/encoding/urlencode.zig");
const numbers_cmd = @import("commands/dev/numbers.zig");
const hmac_cmd = @import("commands/security/hmac.zig");

pub const version = "0.1.0";
pub const app_name = "zuxi";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var args_iter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer args_iter.deinit();

    // Skip program name.
    _ = args_iter.skip();

    // Collect remaining args into a fixed buffer.
    var args_buf: [128][]const u8 = undefined;
    var args_count: usize = 0;
    while (args_iter.next()) |arg| {
        if (args_count >= args_buf.len) {
            try stderr.print("zuxi: warning: too many arguments (limit {d}), remaining args ignored\n", .{args_buf.len});
            break;
        }
        args_buf[args_count] = arg;
        args_count += 1;
    }
    const args_slice = args_buf[0..args_count];

    const reg = registry.getGlobalRegistry();

    // Register commands.
    const commands_to_register = [_]registry.Command{
        jsonfmt.command,
        base64_cmd.command,
        strcase_cmd.command,
        hash_cmd.command,
        jwt_cmd.command,
        time_cmd.command,
        uuid_cmd.command,
        http_cmd.command,
        count_cmd.command,
        slug_cmd.command,
        urlencode_cmd.command,
        numbers_cmd.command,
        hmac_cmd.command,
    };
    for (commands_to_register) |cmd| {
        reg.register(cmd) catch {
            try stderr.print("zuxi: failed to register commands\n", .{});
            std.process.exit(1);
        };
    }

    var positional_buf: [128][]const u8 = undefined;
    const parse_result = cli.parseArgs(args_slice, &positional_buf) catch |err| {
        try errors.printError(stderr, err, null);
        std.process.exit(1);
    };

    switch (parse_result) {
        .version => {
            try cli.printVersion(stdout);
        },
        .help => {
            try cli.printHelp(stdout, reg);
        },
        .command_help => |cmd_name| {
            try cli.printCommandHelp(stdout, reg, cmd_name);
        },
        .tui => {
            const size = tui.getTerminalSize();
            var app = tui.TuiApp.init(allocator, reg, size.cols, size.rows);
            defer app.deinit();
            app.run() catch {
                try stderr.print("zuxi: TUI error, falling back to help\n", .{});
                try cli.printHelp(stdout, reg);
            };
        },
        .command => |invocation| {
            cli.dispatch(reg, invocation, allocator) catch |err| {
                // Try to report as a ZuxiError if possible.
                const zuxi_err: ?errors.ZuxiError = switch (err) {
                    error.InvalidInput => error.InvalidInput,
                    error.IoError => error.IoError,
                    error.FormatError => error.FormatError,
                    error.InvalidArgument => error.InvalidArgument,
                    error.MissingArgument => error.MissingArgument,
                    error.CommandNotFound => error.CommandNotFound,
                    error.Timeout => error.Timeout,
                    error.BufferTooSmall => error.BufferTooSmall,
                    error.NotAvailable => error.NotAvailable,
                    else => null,
                };
                if (zuxi_err) |ze| {
                    try errors.printError(stderr, ze, null);
                } else {
                    try stderr.print("zuxi: unexpected error\n", .{});
                }
                std.process.exit(1);
            };
        },
    }
}

// --- Module references (for test discovery) ---
comptime {
    _ = @import("core/errors.zig");
    _ = @import("core/context.zig");
    _ = @import("core/io.zig");
    _ = @import("core/registry.zig");
    _ = @import("core/cli.zig");
    _ = @import("core/color.zig");
    _ = @import("core/tui.zig");
    _ = @import("commands/json/jsonfmt.zig");
    _ = @import("commands/encoding/base64.zig");
    _ = @import("commands/encoding/strcase.zig");
    _ = @import("commands/security/hash.zig");
    _ = @import("commands/security/jwt.zig");
    _ = @import("commands/time/time.zig");
    _ = @import("commands/dev/uuid.zig");
    _ = @import("commands/dev/http.zig");
    _ = @import("commands/encoding/count.zig");
    _ = @import("commands/encoding/slug.zig");
    _ = @import("commands/encoding/urlencode.zig");
    _ = @import("commands/dev/numbers.zig");
    _ = @import("commands/security/hmac.zig");
    _ = @import("ui/themes/theme.zig");
    _ = @import("ui/components/list.zig");
    _ = @import("ui/components/textinput.zig");
    _ = @import("ui/components/preview.zig");
    _ = @import("ui/layout/split.zig");
}

// --- Tests ---

test "version string is set" {
    try std.testing.expect(version.len > 0);
    try std.testing.expectEqualStrings("0.1.0", version);
}

test "app name is zuxi" {
    try std.testing.expectEqualStrings("zuxi", app_name);
}

test "build mode option exists" {
    const mode = build_options.build_mode;
    try std.testing.expect(mode == .lite or mode == .full);
}
