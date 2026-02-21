const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// A parsed cron field representing which values are valid.
const FieldSet = struct {
    bits: u64 = 0,

    fn set(self: *FieldSet, val: u6) void {
        self.bits |= @as(u64, 1) << val;
    }

    fn isSet(self: FieldSet, val: u6) bool {
        return (self.bits & (@as(u64, 1) << val)) != 0;
    }
};

/// A fully parsed cron expression (5 fields).
const CronExpr = struct {
    minutes: FieldSet, // 0-59
    hours: FieldSet, // 0-23
    doms: FieldSet, // 1-31
    months: FieldSet, // 1-12
    dows: FieldSet, // 0-6 (0=Sunday)
};

/// Parse a single cron field with the given valid range [min, max].
fn parseField(field: []const u8, min: u6, max: u6) ?FieldSet {
    var result = FieldSet{};

    // Split by comma for lists
    var list_iter = std.mem.splitScalar(u8, field, ',');
    while (list_iter.next()) |part| {
        if (part.len == 0) return null;

        // Check for step: X/N
        var step_iter = std.mem.splitScalar(u8, part, '/');
        const range_part = step_iter.next() orelse return null;
        const step_str = step_iter.next();
        if (step_iter.next() != null) return null; // too many slashes

        const step: u6 = if (step_str) |s|
            std.fmt.parseInt(u6, s, 10) catch return null
        else
            1;
        if (step == 0) return null;

        // Parse the range part
        if (std.mem.eql(u8, range_part, "*")) {
            // Wildcard: all values in range
            var v: u6 = min;
            while (v <= max) : (v += step) {
                result.set(v);
                if (v == max) break; // prevent overflow
            }
        } else if (std.mem.indexOf(u8, range_part, "-")) |dash_pos| {
            // Range: A-B
            const start = std.fmt.parseInt(u6, range_part[0..dash_pos], 10) catch return null;
            const end = std.fmt.parseInt(u6, range_part[dash_pos + 1 ..], 10) catch return null;
            if (start < min or end > max or start > end) return null;
            var v: u6 = start;
            while (v <= end) : (v += step) {
                result.set(v);
                if (v == end) break;
            }
        } else {
            // Single value
            const val = std.fmt.parseInt(u6, range_part, 10) catch return null;
            if (val < min or val > max) return null;
            if (step_str != null) {
                // e.g. "5/15" means starting at 5, every 15
                var v: u6 = val;
                while (v <= max) : (v += step) {
                    result.set(v);
                    if (@as(u7, v) + step > max) break;
                }
            } else {
                result.set(val);
            }
        }
    }

    return result;
}

/// Expand a special string (@daily, @hourly, etc.) to a 5-field cron string.
fn expandSpecial(input: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, input, "@yearly") or std.mem.eql(u8, input, "@annually")) {
        return "0 0 1 1 *";
    } else if (std.mem.eql(u8, input, "@monthly")) {
        return "0 0 1 * *";
    } else if (std.mem.eql(u8, input, "@weekly")) {
        return "0 0 * * 0";
    } else if (std.mem.eql(u8, input, "@daily") or std.mem.eql(u8, input, "@midnight")) {
        return "0 0 * * *";
    } else if (std.mem.eql(u8, input, "@hourly")) {
        return "0 * * * *";
    }
    return null;
}

/// Parse a cron expression string into a CronExpr.
fn parseCron(input: []const u8) ?CronExpr {
    // Check for special strings
    const expr = expandSpecial(input) orelse input;

    var fields: [5][]const u8 = undefined;
    var count: usize = 0;
    var iter = std.mem.tokenizeScalar(u8, expr, ' ');
    while (iter.next()) |token| {
        if (count >= 5) return null;
        fields[count] = token;
        count += 1;
    }
    if (count != 5) return null;

    const minutes = parseField(fields[0], 0, 59) orelse return null;
    const hours = parseField(fields[1], 0, 23) orelse return null;
    const doms = parseField(fields[2], 1, 31) orelse return null;
    const months = parseField(fields[3], 1, 12) orelse return null;
    const dows = parseField(fields[4], 0, 6) orelse return null;

    return CronExpr{
        .minutes = minutes,
        .hours = hours,
        .doms = doms,
        .months = months,
        .dows = dows,
    };
}

/// Describe a cron expression in human-readable text.
fn describeCron(cron: CronExpr, buf: []u8) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const w = stream.writer();

    // Describe minutes
    describeFieldPart(w, cron.minutes, 0, 59, "minute") catch return "?";
    w.writeAll(" past ") catch return "?";

    // Describe hours
    describeFieldPart(w, cron.hours, 0, 23, "hour") catch return "?";

    // Describe DOM
    if (!isAllSet(cron.doms, 1, 31)) {
        w.writeAll(" on day ") catch return "?";
        writeSetValues(w, cron.doms, 1, 31) catch return "?";
    }

    // Describe month
    if (!isAllSet(cron.months, 1, 12)) {
        w.writeAll(" in ") catch return "?";
        writeMonthNames(w, cron.months) catch return "?";
    }

    // Describe DOW
    if (!isAllSet(cron.dows, 0, 6)) {
        w.writeAll(" on ") catch return "?";
        writeDowNames(w, cron.dows) catch return "?";
    }

    return stream.getWritten();
}

fn isAllSet(field: FieldSet, min: u6, max: u6) bool {
    var v: u6 = min;
    while (v <= max) : (v += 1) {
        if (!field.isSet(v)) return false;
        if (v == max) break;
    }
    return true;
}

fn describeFieldPart(w: anytype, field: FieldSet, min: u6, max: u6, comptime unit: []const u8) !void {
    if (isAllSet(field, min, max)) {
        try w.writeAll("every " ++ unit);
    } else {
        // Count how many are set
        var count: u32 = 0;
        var v: u6 = min;
        while (v <= max) : (v += 1) {
            if (field.isSet(v)) count += 1;
            if (v == max) break;
        }

        // Check for step pattern
        if (count > 1) {
            const step = detectStep(field, min, max);
            if (step) |s| {
                // Find first set value
                var first: u6 = min;
                var fv: u6 = min;
                while (fv <= max) : (fv += 1) {
                    if (field.isSet(fv)) {
                        first = fv;
                        break;
                    }
                    if (fv == max) break;
                }
                if (first == min) {
                    try w.print("every {d} " ++ unit ++ "s", .{s});
                } else {
                    try w.print("every {d} " ++ unit ++ "s from {d}", .{ s, first });
                }
                return;
            }
        }

        try w.writeAll(unit ++ " ");
        try writeSetValues(w, field, min, max);
    }
}

fn detectStep(field: FieldSet, min: u6, max: u6) ?u6 {
    // Collect set values
    var values: [64]u6 = undefined;
    var count: usize = 0;
    var v: u6 = min;
    while (v <= max) : (v += 1) {
        if (field.isSet(v)) {
            values[count] = v;
            count += 1;
        }
        if (v == max) break;
    }
    if (count < 2) return null;

    const step = values[1] - values[0];
    if (step == 0) return null;
    var i: usize = 1;
    while (i < count) : (i += 1) {
        if (values[i] - values[i - 1] != step) return null;
    }
    return step;
}

fn writeSetValues(w: anytype, field: FieldSet, min: u6, max: u6) !void {
    var first = true;
    var v: u6 = min;
    while (v <= max) : (v += 1) {
        if (field.isSet(v)) {
            if (!first) try w.writeAll(",");
            try w.print("{d}", .{v});
            first = false;
        }
        if (v == max) break;
    }
}

const month_names = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

fn writeMonthNames(w: anytype, field: FieldSet) !void {
    var first = true;
    var m: u6 = 1;
    while (m <= 12) : (m += 1) {
        if (field.isSet(m)) {
            if (!first) try w.writeAll(",");
            try w.writeAll(month_names[m - 1]);
            first = false;
        }
        if (m == 12) break;
    }
}

const dow_names = [_][]const u8{
    "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat",
};

fn writeDowNames(w: anytype, field: FieldSet) !void {
    var first = true;
    var d: u6 = 0;
    while (d <= 6) : (d += 1) {
        if (field.isSet(d)) {
            if (!first) try w.writeAll(",");
            try w.writeAll(dow_names[d]);
            first = false;
        }
        if (d == 6) break;
    }
}

/// Compute the day of week for a given date (0=Sunday).
/// Uses Zeller-like formula (Tomohiko Sakamoto's method).
fn dayOfWeek(year: u16, month: u4, day: u5) u3 {
    const t = [_]u8{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    var y = year;
    if (month < 3) y -= 1;
    const yy: u32 = y;
    const result = (yy + yy / 4 - yy / 100 + yy / 400 + t[month - 1] + day) % 7;
    return @intCast(result);
}

/// Check if a year is a leap year.
fn isLeapYear(y: u16) bool {
    return std.time.epoch.isLeapYear(y);
}

/// Days in a given month.
fn daysInMonth(year: u16, month: u4) u5 {
    const month_enum: std.time.epoch.Month = @enumFromInt(month);
    return std.time.epoch.getDaysInMonth(year, month_enum);
}

/// Advance a datetime by one minute and return the new (year, month, day, hour, minute).
const DateTime = struct {
    year: u16,
    month: u4,
    day: u5,
    hour: u5,
    minute: u6,
};

fn advanceMinute(dt: DateTime) DateTime {
    var result = dt;
    const new_minute: u7 = @as(u7, result.minute) + 1;
    if (new_minute >= 60) {
        result.minute = 0;
        const new_hour: u6 = @as(u6, result.hour) + 1;
        if (new_hour >= 24) {
            result.hour = 0;
            return advanceDay(result);
        } else {
            result.hour = @intCast(new_hour);
        }
    } else {
        result.minute = @intCast(new_minute);
    }
    return result;
}

/// Advance to the next day (resetting hour and minute to 0).
fn advanceDay(dt: DateTime) DateTime {
    var result = dt;
    result.hour = 0;
    result.minute = 0;
    const new_day: u6 = @as(u6, result.day) + 1;
    if (new_day > daysInMonth(result.year, result.month)) {
        result.day = 1;
        const new_month: u5 = @as(u5, result.month) + 1;
        if (new_month > 12) {
            result.month = 1;
            result.year += 1;
        } else {
            result.month = @intCast(new_month);
        }
    } else {
        result.day = @intCast(new_day);
    }
    return result;
}

/// Find the next N matching datetimes for a cron expression, starting from a given timestamp.
fn findNextRuns(cron: CronExpr, start_ts: i64, comptime count: usize) [count]DateTime {
    var results: [count]DateTime = undefined;
    var found: usize = 0;

    // Convert start timestamp to datetime
    const unsigned_ts: u64 = if (start_ts >= 0) @intCast(start_ts) else 0;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = unsigned_ts };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var dt = DateTime{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = month_day.day_index + 1,
        .hour = day_seconds.getHoursIntoDay(),
        .minute = day_seconds.getMinutesIntoHour(),
    };

    // Start from the next minute
    dt = advanceMinute(dt);

    // Search up to 4 years ahead (covers all cron patterns)
    const max_year = dt.year + 4;
    while (found < count and dt.year < max_year) {
        // Check month
        if (!cron.months.isSet(@intCast(dt.month))) {
            // Skip to next month
            const new_month: u5 = @as(u5, dt.month) + 1;
            if (new_month > 12) {
                dt.month = 1;
                dt.year += 1;
            } else {
                dt.month = @intCast(new_month);
            }
            dt.day = 1;
            dt.hour = 0;
            dt.minute = 0;
            continue;
        }

        // Check day of month
        if (!cron.doms.isSet(@intCast(dt.day))) {
            dt = advanceDay(dt);
            continue;
        }

        // Check day of week
        const dow = dayOfWeek(dt.year, dt.month, dt.day);
        if (!cron.dows.isSet(dow)) {
            dt = advanceDay(dt);
            continue;
        }

        // Check hour
        if (!cron.hours.isSet(@intCast(dt.hour))) {
            // Skip to next hour
            const new_hour: u6 = @as(u6, dt.hour) + 1;
            dt.minute = 0;
            if (new_hour >= 24) {
                dt = advanceDay(dt);
            } else {
                dt.hour = @intCast(new_hour);
            }
            continue;
        }

        // Check minute
        if (!cron.minutes.isSet(dt.minute)) {
            dt = advanceMinute(dt);
            continue;
        }

        // Match found
        results[found] = dt;
        found += 1;
        dt = advanceMinute(dt);
    }

    // Fill remaining with zeros if not enough matches
    while (found < count) : (found += 1) {
        results[found] = DateTime{ .year = 0, .month = 1, .day = 1, .hour = 0, .minute = 0 };
    }

    return results;
}

/// Entry point for the cron command.
pub fn execute(ctx: context.Context, _: ?[]const u8) anyerror!void {
    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("cron: no input provided\n", .{});
        try writer.print("Usage: zuxi cron '<cron-expression>'\n", .{});
        try writer.print("       zuxi cron @daily\n", .{});
        try writer.print("Examples: '*/5 * * * *', '0 9 * * 1-5', '@hourly'\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    if (input.data.len == 0) {
        const writer = ctx.stderrWriter();
        try writer.print("cron: empty expression\n", .{});
        return error.MissingArgument;
    }

    const cron = parseCron(input.data) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("cron: invalid cron expression: '{s}'\n", .{input.data});
        try writer.print("Expected: 5 fields (minute hour day-of-month month day-of-week)\n", .{});
        try writer.print("  or special: @yearly @monthly @weekly @daily @hourly\n", .{});
        return error.InvalidInput;
    };

    // Build output
    var desc_buf: [512]u8 = undefined;
    const description = describeCron(cron, &desc_buf);

    const now_ts = std.time.timestamp();
    const runs = findNextRuns(cron, now_ts, 5);

    // Write output
    var out_buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&out_buf);
    const w = stream.writer();

    w.print("Expression: {s}\n", .{input.data}) catch return error.BufferTooSmall;
    w.print("Schedule:   {s}\n", .{description}) catch return error.BufferTooSmall;
    w.writeAll("\nNext 5 runs:\n") catch return error.BufferTooSmall;

    for (runs) |run| {
        if (run.year == 0) break;
        w.print("  {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}\n", .{
            run.year, @as(u8, run.month), @as(u8, run.day),
            @as(u8, run.hour), @as(u8, run.minute),
        }) catch return error.BufferTooSmall;
    }

    try io.writeOutput(ctx, stream.getWritten());
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "cron",
    .description = "Parse and explain cron expressions, show next run times",
    .category = .time,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_cron_out.tmp";
    const tmp_in = "zuxi_test_cron_in.tmp";
    const out_file = try std.fs.cwd().createFile(tmp_out, .{});

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

    execute(ctx, null) catch |err| {
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

test "cron parse every minute" {
    const output = try execWithInput("* * * * *");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Expression: * * * * *") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Next 5 runs:") != null);
}

test "cron parse every 5 minutes" {
    const output = try execWithInput("*/5 * * * *");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Expression: */5 * * * *") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "every 5 minutes") != null);
}

test "cron parse specific time" {
    const output = try execWithInput("30 9 * * *");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Expression: 30 9 * * *") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "minute 30") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hour 9") != null);
}

test "cron @daily special string" {
    const output = try execWithInput("@daily");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Expression: @daily") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Next 5 runs:") != null);
}

test "cron @hourly special string" {
    const output = try execWithInput("@hourly");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Expression: @hourly") != null);
}

test "cron @weekly special string" {
    const output = try execWithInput("@weekly");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Expression: @weekly") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Sun") != null);
}

test "cron @monthly special string" {
    const output = try execWithInput("@monthly");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Expression: @monthly") != null);
}

test "cron @yearly special string" {
    const output = try execWithInput("@yearly");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Expression: @yearly") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Jan") != null);
}

test "cron weekday range" {
    const output = try execWithInput("0 9 * * 1-5");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Mon") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Fri") != null);
    // Sunday should not appear
    try std.testing.expect(std.mem.indexOf(u8, output, "Sun") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Sat") == null);
}

test "cron list values" {
    const output = try execWithInput("0 9,17 * * *");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "9") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "17") != null);
}

test "cron invalid expression" {
    const result = execWithInput("not a cron");
    try std.testing.expectError(error.InvalidInput, result);
}

test "cron too few fields" {
    const result = execWithInput("* * *");
    try std.testing.expectError(error.InvalidInput, result);
}

test "cron too many fields" {
    const result = execWithInput("* * * * * *");
    try std.testing.expectError(error.InvalidInput, result);
}

test "cron no input" {
    const result = execWithInput(null);
    try std.testing.expectError(error.MissingArgument, result);
}

test "cron out of range minute" {
    const result = execWithInput("60 * * * *");
    try std.testing.expectError(error.InvalidInput, result);
}

test "cron out of range hour" {
    const result = execWithInput("0 24 * * *");
    try std.testing.expectError(error.InvalidInput, result);
}

test "cron specific month" {
    const output = try execWithInput("0 0 1 6 *");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Jun") != null);
}

test "cron command struct fields" {
    try std.testing.expectEqualStrings("cron", command.name);
    try std.testing.expectEqual(registry.Category.time, command.category);
    try std.testing.expectEqual(@as(usize, 0), command.subcommands.len);
}

test "parseCron returns null for invalid" {
    try std.testing.expect(parseCron("invalid") == null);
    try std.testing.expect(parseCron("") == null);
    try std.testing.expect(parseCron("* *") == null);
}

test "parseCron parses valid expressions" {
    const c1 = parseCron("* * * * *");
    try std.testing.expect(c1 != null);

    const c2 = parseCron("0 0 1 1 *");
    try std.testing.expect(c2 != null);
    try std.testing.expect(c2.?.minutes.isSet(0));
    try std.testing.expect(!c2.?.minutes.isSet(1));
    try std.testing.expect(c2.?.hours.isSet(0));
    try std.testing.expect(!c2.?.hours.isSet(1));
}

test "parseField with step" {
    const field = parseField("*/15", 0, 59);
    try std.testing.expect(field != null);
    try std.testing.expect(field.?.isSet(0));
    try std.testing.expect(field.?.isSet(15));
    try std.testing.expect(field.?.isSet(30));
    try std.testing.expect(field.?.isSet(45));
    try std.testing.expect(!field.?.isSet(5));
}

test "parseField with range" {
    const field = parseField("1-5", 0, 6);
    try std.testing.expect(field != null);
    try std.testing.expect(!field.?.isSet(0));
    try std.testing.expect(field.?.isSet(1));
    try std.testing.expect(field.?.isSet(3));
    try std.testing.expect(field.?.isSet(5));
    try std.testing.expect(!field.?.isSet(6));
}

test "parseField with list" {
    const field = parseField("1,3,5", 1, 12);
    try std.testing.expect(field != null);
    try std.testing.expect(field.?.isSet(1));
    try std.testing.expect(!field.?.isSet(2));
    try std.testing.expect(field.?.isSet(3));
    try std.testing.expect(!field.?.isSet(4));
    try std.testing.expect(field.?.isSet(5));
}

test "dayOfWeek known dates" {
    // 2024-01-01 is a Monday
    try std.testing.expectEqual(@as(u3, 1), dayOfWeek(2024, 1, 1));
    // 2024-01-07 is a Sunday
    try std.testing.expectEqual(@as(u3, 0), dayOfWeek(2024, 1, 7));
    // 1970-01-01 is a Thursday
    try std.testing.expectEqual(@as(u3, 4), dayOfWeek(1970, 1, 1));
}

test "findNextRuns produces valid dates" {
    // Every minute: should give 5 consecutive minutes
    const cron = parseCron("* * * * *").?;
    // Use a known timestamp: 2024-01-15 10:30:00 = 1705314600
    const runs = findNextRuns(cron, 1705314600, 5);
    // First run should be 10:31
    try std.testing.expectEqual(@as(u6, 31), runs[0].minute);
    try std.testing.expectEqual(@as(u5, 10), runs[0].hour);
    // Second run should be 10:32
    try std.testing.expectEqual(@as(u6, 32), runs[1].minute);
}

test "expandSpecial known strings" {
    try std.testing.expect(expandSpecial("@daily") != null);
    try std.testing.expect(expandSpecial("@hourly") != null);
    try std.testing.expect(expandSpecial("@weekly") != null);
    try std.testing.expect(expandSpecial("@monthly") != null);
    try std.testing.expect(expandSpecial("@yearly") != null);
    try std.testing.expect(expandSpecial("@annually") != null);
    try std.testing.expect(expandSpecial("@midnight") != null);
    try std.testing.expect(expandSpecial("invalid") == null);
}
