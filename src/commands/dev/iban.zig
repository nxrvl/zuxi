const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// Country IBAN configuration: country code, total IBAN length, BBAN format description.
const CountryConfig = struct {
    code: []const u8,
    length: u8,
    name: []const u8,
};

/// Supported countries for IBAN validation and generation.
const countries = [_]CountryConfig{
    .{ .code = "DE", .length = 22, .name = "Germany" },
    .{ .code = "GB", .length = 22, .name = "United Kingdom" },
    .{ .code = "FR", .length = 27, .name = "France" },
    .{ .code = "ES", .length = 24, .name = "Spain" },
    .{ .code = "IT", .length = 27, .name = "Italy" },
    .{ .code = "NL", .length = 18, .name = "Netherlands" },
    .{ .code = "BE", .length = 16, .name = "Belgium" },
    .{ .code = "AT", .length = 20, .name = "Austria" },
    .{ .code = "CH", .length = 21, .name = "Switzerland" },
    .{ .code = "PL", .length = 28, .name = "Poland" },
    .{ .code = "PT", .length = 25, .name = "Portugal" },
    .{ .code = "SE", .length = 24, .name = "Sweden" },
    .{ .code = "NO", .length = 15, .name = "Norway" },
    .{ .code = "DK", .length = 18, .name = "Denmark" },
    .{ .code = "FI", .length = 18, .name = "Finland" },
    .{ .code = "IE", .length = 22, .name = "Ireland" },
    .{ .code = "LU", .length = 20, .name = "Luxembourg" },
    .{ .code = "CZ", .length = 24, .name = "Czech Republic" },
    .{ .code = "RO", .length = 24, .name = "Romania" },
    .{ .code = "HR", .length = 21, .name = "Croatia" },
    .{ .code = "BG", .length = 22, .name = "Bulgaria" },
    .{ .code = "HU", .length = 28, .name = "Hungary" },
    .{ .code = "SK", .length = 24, .name = "Slovakia" },
    .{ .code = "SI", .length = 19, .name = "Slovenia" },
    .{ .code = "LT", .length = 20, .name = "Lithuania" },
    .{ .code = "LV", .length = 21, .name = "Latvia" },
    .{ .code = "EE", .length = 20, .name = "Estonia" },
    .{ .code = "GR", .length = 27, .name = "Greece" },
    .{ .code = "CY", .length = 28, .name = "Cyprus" },
    .{ .code = "MT", .length = 31, .name = "Malta" },
};

/// Look up country config by country code.
fn getCountryConfig(code: []const u8) ?CountryConfig {
    for (countries) |c| {
        if (std.mem.eql(u8, c.code, code)) return c;
    }
    return null;
}

/// Validate an IBAN string according to ISO 13616.
pub fn validateIban(iban_raw: []const u8) IbanValidation {
    // Remove spaces.
    var clean: [64]u8 = undefined;
    var clean_len: usize = 0;
    for (iban_raw) |ch| {
        if (ch == ' ' or ch == '-') continue;
        const upper = std.ascii.toUpper(ch);
        if (clean_len >= clean.len) return .{ .valid = false, .reason = "IBAN too long" };
        clean[clean_len] = upper;
        clean_len += 1;
    }

    if (clean_len < 5) return .{ .valid = false, .reason = "IBAN too short (minimum 5 characters)" };

    const cleaned = clean[0..clean_len];

    // Check country code (first 2 chars must be letters).
    if (!std.ascii.isAlphabetic(cleaned[0]) or !std.ascii.isAlphabetic(cleaned[1])) {
        return .{ .valid = false, .reason = "Invalid country code" };
    }

    // Check digits (chars 2-3 must be digits).
    if (!std.ascii.isDigit(cleaned[2]) or !std.ascii.isDigit(cleaned[3])) {
        return .{ .valid = false, .reason = "Invalid check digits" };
    }

    // Check BBAN (remaining chars must be alphanumeric).
    for (cleaned[4..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch)) {
            return .{ .valid = false, .reason = "BBAN contains invalid characters" };
        }
    }

    // Check country-specific length if known.
    const country_code = cleaned[0..2];
    if (getCountryConfig(country_code)) |config| {
        if (clean_len != config.length) {
            return .{ .valid = false, .reason = "Wrong length for country" };
        }
    }

    // ISO 13616 check digit validation:
    // 1. Move first 4 chars to end.
    // 2. Replace letters with numbers (A=10, B=11, ..., Z=35).
    // 3. Compute mod 97. Result must be 1.
    if (!checkMod97(cleaned)) {
        return .{ .valid = false, .reason = "Check digit validation failed" };
    }

    return .{
        .valid = true,
        .reason = "Valid IBAN",
        .country = country_code,
        .country_name = if (getCountryConfig(country_code)) |c| c.name else null,
    };
}

const IbanValidation = struct {
    valid: bool,
    reason: []const u8,
    country: ?[]const u8 = null,
    country_name: ?[]const u8 = null,
};

/// ISO 13616 mod-97 check.
fn checkMod97(iban: []const u8) bool {
    return computeMod97(iban) == 1;
}

/// Compute mod 97 of the IBAN with rearranged digits.
fn computeMod97(iban: []const u8) u32 {
    // Process: move first 4 chars to end, convert letters to numbers, compute mod 97.
    var remainder: u32 = 0;

    // Process chars 4..end first, then chars 0..4.
    var i: usize = 4;
    while (i < iban.len) : (i += 1) {
        processChar(iban[i], &remainder);
    }
    i = 0;
    while (i < 4) : (i += 1) {
        processChar(iban[i], &remainder);
    }

    return remainder;
}

fn processChar(ch: u8, remainder: *u32) void {
    if (std.ascii.isDigit(ch)) {
        remainder.* = (remainder.* * 10 + (ch - '0')) % 97;
    } else {
        // Letter: A=10, B=11, ..., Z=35 (two digits).
        const val: u32 = ch - 'A' + 10;
        remainder.* = (remainder.* * 100 + val) % 97;
    }
}

/// Generate a valid IBAN for a given country code.
fn generateIban(country_code: []const u8) ?[64]u8 {
    const config = getCountryConfig(country_code) orelse return null;

    var result: [64]u8 = undefined;
    result[0] = country_code[0];
    result[1] = country_code[1];
    result[2] = '0'; // placeholder check digits
    result[3] = '0';

    // Fill BBAN with example digits.
    const bban_len = config.length - 4;
    var i: usize = 0;
    while (i < bban_len) : (i += 1) {
        // Use a pattern of digits for the BBAN.
        result[4 + i] = '0' + @as(u8, @intCast((i + 1) % 10));
    }

    // Compute check digits: set check digits to 00, compute mod 97, check = 98 - mod.
    const iban_slice = result[0..config.length];
    const mod = computeMod97(iban_slice);
    const check: u32 = 98 - mod;
    result[2] = '0' + @as(u8, @intCast(check / 10));
    result[3] = '0' + @as(u8, @intCast(check % 10));

    return result;
}

/// Entry point for the iban command.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    const mode: enum { validate, generate } = if (subcommand) |sub| blk: {
        if (std.mem.eql(u8, sub, "validate")) break :blk .validate;
        if (std.mem.eql(u8, sub, "generate")) break :blk .generate;
        const writer = ctx.stderrWriter();
        try writer.print("iban: unknown subcommand '{s}'\n", .{sub});
        try writer.print("Available subcommands: validate, generate\n", .{});
        return error.InvalidArgument;
    } else .validate;

    switch (mode) {
        .validate => {
            const input = try io.getInput(ctx);
            if (input) |inp| {
                defer inp.deinit(ctx.allocator);
                if (inp.data.len == 0) {
                    const writer = ctx.stderrWriter();
                    try writer.print("iban validate: IBAN required\n", .{});
                    try writer.print("Usage: zuxi iban validate <iban>\n", .{});
                    return error.MissingArgument;
                }
                const result = validateIban(inp.data);
                const writer = ctx.stdoutWriter();
                if (result.valid) {
                    try writer.print("Valid IBAN\n", .{});
                    if (result.country) |cc| {
                        try writer.print("Country: {s}", .{cc});
                        if (result.country_name) |name| {
                            try writer.print(" ({s})", .{name});
                        }
                        try writer.print("\n", .{});
                    }
                } else {
                    try writer.print("Invalid IBAN: {s}\n", .{result.reason});
                }
            } else {
                const writer = ctx.stderrWriter();
                try writer.print("iban validate: IBAN required\n", .{});
                try writer.print("Usage: zuxi iban validate <iban>\n", .{});
                return error.MissingArgument;
            }
        },
        .generate => {
            if (ctx.args.len == 0) {
                const writer = ctx.stderrWriter();
                try writer.print("iban generate: country code required\n", .{});
                try writer.print("Usage: zuxi iban generate <country_code>\n", .{});
                return error.MissingArgument;
            }

            // Uppercase the country code.
            var code_buf: [2]u8 = undefined;
            const raw_code = ctx.args[0];
            if (raw_code.len != 2) {
                const writer = ctx.stderrWriter();
                try writer.print("iban generate: country code must be 2 letters\n", .{});
                return error.InvalidArgument;
            }
            code_buf[0] = std.ascii.toUpper(raw_code[0]);
            code_buf[1] = std.ascii.toUpper(raw_code[1]);
            const code = code_buf[0..2];

            const config = getCountryConfig(code) orelse {
                const writer = ctx.stderrWriter();
                try writer.print("iban generate: unsupported country code '{s}'\n", .{code});
                return error.InvalidArgument;
            };

            const result = generateIban(code) orelse {
                const writer = ctx.stderrWriter();
                try writer.print("iban generate: failed to generate IBAN\n", .{});
                return error.InvalidInput;
            };

            const writer = ctx.stdoutWriter();
            try writer.print("{s}\n", .{result[0..config.length]});
        },
    }
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "iban",
    .description = "IBAN validation and generation",
    .category = .dev,
    .subcommands = &.{ "validate", "generate" },
    .execute = execute,
};

// --- Tests ---

fn execIban(subcommand: ?[]const u8, args: []const []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_iban_out.tmp";

    const out_file = try std.fs.cwd().createFile(tmp_out, .{});

    var ctx = context.Context.initDefault(allocator);
    ctx.stdout = out_file;
    ctx.args = args;

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

test "iban validate valid DE IBAN" {
    // DE89370400440532013000 is a well-known test IBAN.
    const args = [_][]const u8{"DE89370400440532013000"};
    const output = try execIban("validate", &args);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Valid IBAN") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Germany") != null);
}

test "iban validate valid GB IBAN" {
    // GB29NWBK60161331926819 is a well-known test IBAN.
    const args = [_][]const u8{"GB29NWBK60161331926819"};
    const output = try execIban("validate", &args);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Valid IBAN") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "United Kingdom") != null);
}

test "iban validate with spaces" {
    const args = [_][]const u8{"DE89 3704 0044 0532 0130 00"};
    const output = try execIban("validate", &args);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Valid IBAN") != null);
}

test "iban validate invalid check digit" {
    const args = [_][]const u8{"DE00370400440532013000"};
    const output = try execIban("validate", &args);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Invalid IBAN") != null);
}

test "iban validate too short" {
    const args = [_][]const u8{"DE89"};
    const output = try execIban("validate", &args);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Invalid IBAN") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "too short") != null);
}

test "iban validate wrong length for country" {
    const args = [_][]const u8{"DE8937040044053201300"};  // 21 chars instead of 22
    const output = try execIban("validate", &args);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Invalid IBAN") != null);
}

test "iban validate lowercase accepted" {
    const args = [_][]const u8{"de89370400440532013000"};
    const output = try execIban("validate", &args);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Valid IBAN") != null);
}

test "iban generate DE" {
    const args = [_][]const u8{"DE"};
    const output = try execIban("generate", &args);
    defer std.testing.allocator.free(output);
    try std.testing.expect(output.len >= 22);
    try std.testing.expect(std.mem.startsWith(u8, output, "DE"));
    // Validate the generated IBAN.
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    const validation = validateIban(trimmed);
    try std.testing.expect(validation.valid);
}

test "iban generate GB" {
    const args = [_][]const u8{"GB"};
    const output = try execIban("generate", &args);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.startsWith(u8, output, "GB"));
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    const validation = validateIban(trimmed);
    try std.testing.expect(validation.valid);
}

test "iban generate lowercase" {
    const args = [_][]const u8{"de"};
    const output = try execIban("generate", &args);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.startsWith(u8, output, "DE"));
}

test "iban generate unsupported country" {
    const args = [_][]const u8{"ZZ"};
    const result = execIban("generate", &args);
    try std.testing.expectError(error.InvalidArgument, result);
}

test "iban generate no args returns error" {
    const args = [_][]const u8{};
    const result = execIban("generate", &args);
    try std.testing.expectError(error.MissingArgument, result);
}

test "iban generate invalid code length" {
    const args = [_][]const u8{"DEX"};
    const result = execIban("generate", &args);
    try std.testing.expectError(error.InvalidArgument, result);
}

test "iban validate no input returns error" {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_iban_noinput.tmp";
    const tmp_stdin = "zuxi_test_iban_stdin.tmp";
    // Create empty stdin file to avoid blocking on pipe read.
    const sf = try std.fs.cwd().createFile(tmp_stdin, .{});
    sf.close();
    const stdin_rd = try std.fs.cwd().openFile(tmp_stdin, .{});
    const out_file = try std.fs.cwd().createFile(tmp_out, .{});
    var ctx = context.Context.initDefault(allocator);
    ctx.stdout = out_file;
    ctx.stdin = stdin_rd;
    const result = execute(ctx, "validate");
    stdin_rd.close();
    out_file.close();
    std.fs.cwd().deleteFile(tmp_out) catch {};
    std.fs.cwd().deleteFile(tmp_stdin) catch {};
    try std.testing.expectError(error.MissingArgument, result);
}

test "iban unknown subcommand returns error" {
    const args = [_][]const u8{};
    const result = execIban("unknown", &args);
    try std.testing.expectError(error.InvalidArgument, result);
}

test "iban command struct fields" {
    try std.testing.expectEqualStrings("iban", command.name);
    try std.testing.expectEqual(registry.Category.dev, command.category);
    try std.testing.expectEqual(@as(usize, 2), command.subcommands.len);
}

// Unit tests for validation logic.
test "validateIban valid FR IBAN" {
    const result = validateIban("FR7630006000011234567890189");
    try std.testing.expect(result.valid);
}

test "validateIban invalid country code" {
    const result = validateIban("12345678901234");
    try std.testing.expect(!result.valid);
}

test "checkMod97 known value" {
    // DE89370400440532013000 should have mod97 == 1.
    try std.testing.expectEqual(@as(u32, 1), computeMod97("DE89370400440532013000"));
}

test "getCountryConfig returns config for known country" {
    const config = getCountryConfig("DE");
    try std.testing.expect(config != null);
    try std.testing.expectEqual(@as(u8, 22), config.?.length);
    try std.testing.expectEqualStrings("Germany", config.?.name);
}

test "getCountryConfig returns null for unknown" {
    try std.testing.expect(getCountryConfig("ZZ") == null);
}
