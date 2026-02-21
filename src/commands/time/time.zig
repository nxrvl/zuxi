const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// Entry point for the time command.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    const sub = subcommand orelse "now";

    if (std.mem.eql(u8, sub, "now")) {
        try showCurrentTime(ctx);
    } else if (std.mem.eql(u8, sub, "unix")) {
        try unixToRfc3339(ctx);
    } else if (std.mem.eql(u8, sub, "rfc3339")) {
        try rfc3339ToUnix(ctx);
    } else {
        const writer = ctx.stderrWriter();
        try writer.print("time: unknown subcommand '{s}'\n", .{sub});
        try writer.print("Available subcommands: now, unix, rfc3339\n", .{});
        return error.InvalidArgument;
    }
}

/// Show current time in both UTC RFC3339 and Unix timestamp.
fn showCurrentTime(ctx: context.Context) anyerror!void {
    const ts = std.time.timestamp();
    const unsigned_ts: u64 = if (ts >= 0) @intCast(ts) else 0;

    var buf: [256]u8 = undefined;
    const rfc3339_str = formatRfc3339(unsigned_ts, &buf);

    var out_buf: [512]u8 = undefined;
    const n = std.fmt.bufPrint(&out_buf, "Unix:    {d}\nRFC3339: {s}\n", .{ ts, rfc3339_str }) catch return error.BufferTooSmall;
    try io.writeOutput(ctx, n);
}

/// Convert an RFC3339 string to a Unix timestamp.
fn rfc3339ToUnix(ctx: context.Context) anyerror!void {
    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("time: no input provided\n", .{});
        try writer.print("Usage: zuxi time rfc3339 <rfc3339-string>\n", .{});
        try writer.print("       echo '2024-01-15T10:30:00Z' | zuxi time rfc3339\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    if (input.data.len == 0) {
        const writer = ctx.stderrWriter();
        try writer.print("time: no input provided\n", .{});
        return error.MissingArgument;
    }

    const ts = parseRfc3339(input.data) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("time: invalid RFC3339 format: '{s}'\n", .{input.data});
        try writer.print("Expected format: YYYY-MM-DDThh:mm:ssZ or YYYY-MM-DDThh:mm:ss+HH:MM\n", .{});
        return error.InvalidInput;
    };

    var out_buf: [64]u8 = undefined;
    const n = std.fmt.bufPrint(&out_buf, "{d}\n", .{ts}) catch return error.BufferTooSmall;
    try io.writeOutput(ctx, n);
}

/// Convert a Unix timestamp to an RFC3339 string.
fn unixToRfc3339(ctx: context.Context) anyerror!void {
    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("time: no input provided\n", .{});
        try writer.print("Usage: zuxi time unix <unix-timestamp>\n", .{});
        try writer.print("       echo '1705314600' | zuxi time unix\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    if (input.data.len == 0) {
        const writer = ctx.stderrWriter();
        try writer.print("time: no input provided\n", .{});
        return error.MissingArgument;
    }

    const ts = std.fmt.parseInt(i64, input.data, 10) catch {
        const writer = ctx.stderrWriter();
        try writer.print("time: invalid Unix timestamp: '{s}'\n", .{input.data});
        return error.InvalidInput;
    };

    const unsigned_ts: u64 = if (ts >= 0) @intCast(ts) else {
        const writer = ctx.stderrWriter();
        try writer.print("time: negative timestamps not supported\n", .{});
        return error.InvalidInput;
    };

    var buf: [64]u8 = undefined;
    const rfc3339_str = formatRfc3339(unsigned_ts, &buf);

    var out_buf: [128]u8 = undefined;
    const n = std.fmt.bufPrint(&out_buf, "{s}\n", .{rfc3339_str}) catch return error.BufferTooSmall;
    try io.writeOutput(ctx, n);
}

/// Format a Unix timestamp (seconds since epoch) as an RFC3339 string.
/// Returns a slice into the provided buffer.
pub fn formatRfc3339(timestamp: u64, buf: []u8) []const u8 {
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = timestamp };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const year = year_day.year;
    const month = month_day.month.numeric();
    const day = month_day.day_index + 1; // day_index is 0-based
    const hours = day_seconds.getHoursIntoDay();
    const minutes = day_seconds.getMinutesIntoHour();
    const seconds = day_seconds.getSecondsIntoMinute();

    const result = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year, month, day, hours, minutes, seconds,
    }) catch return "0000-00-00T00:00:00Z";

    return result;
}

/// Parse an RFC3339 string into a Unix timestamp (seconds since epoch).
/// Supports formats: YYYY-MM-DDThh:mm:ssZ and YYYY-MM-DDThh:mm:ss+HH:MM / -HH:MM
/// Returns null if parsing fails.
pub fn parseRfc3339(input: []const u8) ?i64 {
    // Minimum length: "YYYY-MM-DDThh:mm:ssZ" = 20
    if (input.len < 20) return null;

    // Parse date part: YYYY-MM-DD
    const year = std.fmt.parseInt(u16, input[0..4], 10) catch return null;
    if (input[4] != '-') return null;
    const month = std.fmt.parseInt(u4, input[5..7], 10) catch return null;
    if (input[7] != '-') return null;
    const day = std.fmt.parseInt(u5, input[8..10], 10) catch return null;

    // Separator must be 'T' or 't'
    if (input[10] != 'T' and input[10] != 't') return null;

    // Parse time part: hh:mm:ss
    const hours = std.fmt.parseInt(u5, input[11..13], 10) catch return null;
    if (input[13] != ':') return null;
    const minutes = std.fmt.parseInt(u6, input[14..16], 10) catch return null;
    if (input[16] != ':') return null;
    const seconds = std.fmt.parseInt(u6, input[17..19], 10) catch return null;

    // Validate ranges
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;
    if (hours > 23) return null;
    if (minutes > 59) return null;
    if (seconds > 59) return null;

    // Parse timezone offset
    var tz_offset_seconds: i64 = 0;
    if (input.len >= 20) {
        const tz_char = input[19];
        if (tz_char == 'Z' or tz_char == 'z') {
            if (input.len != 20) return null; // reject trailing characters
            tz_offset_seconds = 0;
        } else if (tz_char == '+' or tz_char == '-') {
            if (input.len < 25) return null;
            const tz_hours = std.fmt.parseInt(i64, input[20..22], 10) catch return null;
            if (input[22] != ':') return null;
            const tz_minutes = std.fmt.parseInt(i64, input[23..25], 10) catch return null;
            if (input.len != 25) return null; // reject trailing characters
            tz_offset_seconds = (tz_hours * 3600) + (tz_minutes * 60);
            if (tz_char == '-') {
                tz_offset_seconds = -tz_offset_seconds;
            }
        } else {
            return null;
        }
    }

    // Convert date to days since epoch
    const days = dateToDays(year, month, day) orelse return null;
    const total_seconds: i64 = days * 86400 + @as(i64, hours) * 3600 + @as(i64, minutes) * 60 + @as(i64, seconds);

    return total_seconds - tz_offset_seconds;
}

/// Convert a date (year, month, day) to days since Unix epoch.
fn dateToDays(year: u16, month: u4, day: u5) ?i64 {
    if (year < 1970) return null;

    var total_days: i64 = 0;

    // Add days for full years
    var y: u16 = 1970;
    while (y < year) : (y += 1) {
        total_days += if (std.time.epoch.isLeapYear(y)) @as(i64, 366) else @as(i64, 365);
    }

    // Add days for full months in the current year
    const month_enum: std.time.epoch.Month = @enumFromInt(month);
    var m: u4 = 1;
    while (m < month) : (m += 1) {
        const me: std.time.epoch.Month = @enumFromInt(m);
        total_days += @as(i64, std.time.epoch.getDaysInMonth(year, me));
    }

    // Validate day for the month
    const days_in_month = std.time.epoch.getDaysInMonth(year, month_enum);
    if (day > days_in_month or day == 0) return null;

    total_days += @as(i64, day) - 1; // day is 1-based
    return total_days;
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "time",
    .description = "Convert between Unix timestamps and RFC3339, show current time",
    .category = .time,
    .subcommands = &.{ "now", "unix", "rfc3339" },
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: ?[]const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_time_out.tmp";
    const tmp_in = "zuxi_test_time_in.tmp";
    const out_file = try std.fs.cwd().createFile(tmp_out, .{});

    // Create an empty stdin file so getInput won't block on real stdin.
    const empty_in = try std.fs.cwd().createFile(tmp_in, .{});
    empty_in.close();
    const stdin_file = try std.fs.cwd().openFile(tmp_in, .{});

    var args_buf: [1][]const u8 = undefined;
    var args_slice: []const []const u8 = &.{};
    if (input) |inp| {
        args_buf[0] = inp;
        args_slice = args_buf[0..1];
    }

    var ctx = context.Context.initDefault(allocator);
    ctx.args = args_slice;
    ctx.stdout = out_file;
    ctx.stdin = stdin_file;

    execute(ctx, subcommand) catch |err| {
        out_file.close();
        stdin_file.close();
        std.fs.cwd().deleteFile(tmp_out) catch {};
        std.fs.cwd().deleteFile(tmp_in) catch {};
        return err;
    };
    out_file.close();
    stdin_file.close();
    std.fs.cwd().deleteFile(tmp_in) catch {};

    const file = try std.fs.cwd().openFile(tmp_out, .{});
    defer file.close();
    defer std.fs.cwd().deleteFile(tmp_out) catch {};
    return try file.readToEndAlloc(allocator, io.max_input_size);
}

test "time unix converts timestamp to rfc3339" {
    // 1705314600 = 2024-01-15T10:30:00Z
    const output = try execWithInput("1705314600", "unix");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("2024-01-15T10:30:00Z", trimmed);
}

test "time unix from epoch zero" {
    const output = try execWithInput("0", "unix");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", trimmed);
}

test "time rfc3339 converts to unix timestamp" {
    const output = try execWithInput("2024-01-15T10:30:00Z", "rfc3339");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("1705314600", trimmed);
}

test "time rfc3339 from epoch start" {
    const output = try execWithInput("1970-01-01T00:00:00Z", "rfc3339");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("0", trimmed);
}

test "time rfc3339 with positive offset" {
    // 2024-01-15T12:30:00+02:00 = 2024-01-15T10:30:00Z = 1705314600
    const output = try execWithInput("2024-01-15T12:30:00+02:00", "rfc3339");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("1705314600", trimmed);
}

test "time rfc3339 with negative offset" {
    // 2024-01-15T05:30:00-05:00 = 2024-01-15T10:30:00Z = 1705314600
    const output = try execWithInput("2024-01-15T05:30:00-05:00", "rfc3339");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("1705314600", trimmed);
}

test "time roundtrip: unix -> rfc3339 -> unix" {
    // Convert 1705314600 via unix subcommand (outputs rfc3339)
    const rfc_output = try execWithInput("1705314600", "unix");
    defer std.testing.allocator.free(rfc_output);
    const rfc_trimmed = std.mem.trimRight(u8, rfc_output, &std.ascii.whitespace);

    // Convert back via rfc3339 subcommand (outputs unix)
    const unix_output = try execWithInput(rfc_trimmed, "rfc3339");
    defer std.testing.allocator.free(unix_output);
    const unix_trimmed = std.mem.trimRight(u8, unix_output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("1705314600", unix_trimmed);
}

test "time rfc3339 invalid input" {
    const result = execWithInput("not-a-date", "rfc3339");
    try std.testing.expectError(error.InvalidInput, result);
}

test "time unix invalid input" {
    const result = execWithInput("not-a-number", "unix");
    try std.testing.expectError(error.InvalidInput, result);
}

test "time unknown subcommand" {
    const result = execWithInput(null, "invalid");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "time no input for unix subcommand" {
    const result = execWithInput(null, "unix");
    try std.testing.expectError(error.MissingArgument, result);
}

test "time no input for rfc3339 subcommand" {
    const result = execWithInput(null, "rfc3339");
    try std.testing.expectError(error.MissingArgument, result);
}

test "time command struct fields" {
    try std.testing.expectEqualStrings("time", command.name);
    try std.testing.expectEqual(registry.Category.time, command.category);
    try std.testing.expectEqual(@as(usize, 3), command.subcommands.len);
}

test "formatRfc3339 known values" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", formatRfc3339(0, &buf));
    try std.testing.expectEqualStrings("2024-01-15T10:30:00Z", formatRfc3339(1705314600, &buf));
}

test "parseRfc3339 known values" {
    try std.testing.expectEqual(@as(?i64, 0), parseRfc3339("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(?i64, 1705314600), parseRfc3339("2024-01-15T10:30:00Z"));
    try std.testing.expectEqual(@as(?i64, null), parseRfc3339("invalid"));
    try std.testing.expectEqual(@as(?i64, null), parseRfc3339(""));
    // Trailing garbage must be rejected
    try std.testing.expectEqual(@as(?i64, null), parseRfc3339("2024-01-15T10:30:00Zgarbage"));
    try std.testing.expectEqual(@as(?i64, null), parseRfc3339("2024-01-15T10:30:00+02:00extra"));
}
