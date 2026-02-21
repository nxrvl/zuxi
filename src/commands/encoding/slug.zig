const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// Entry point for the slug command.
/// Converts text to a URL-friendly slug.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    if (subcommand) |sub| {
        const writer = ctx.stderrWriter();
        try writer.print("slug: unknown subcommand '{s}'\n", .{sub});
        return error.InvalidArgument;
    }

    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("slug: no input provided\n", .{});
        try writer.print("Usage: zuxi slug <text>\n", .{});
        try writer.print("       echo 'text' | zuxi slug\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    const result = try slugify(ctx.allocator, input.data);
    defer ctx.allocator.free(result);

    try io.writeOutput(ctx, result);
}

/// Convert text to a URL-friendly slug.
/// - Transliterate Cyrillic to Latin
/// - Lowercase ASCII
/// - Replace spaces/special chars with hyphens
/// - Strip non-ASCII, non-alphanumeric, non-hyphen chars
/// - Collapse multiple hyphens, trim leading/trailing hyphens
fn slugify(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // First pass: transliterate and build a buffer.
    var list = std.ArrayList(u8){};
    defer list.deinit(allocator);

    var view = std.unicode.Utf8View.initUnchecked(input);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (transliterateCyrillic(cp)) |latin| {
            for (latin) |c| {
                try list.append(allocator, std.ascii.toLower(c));
            }
        } else if (cp < 128) {
            const c: u8 = @intCast(cp);
            if (std.ascii.isAlphanumeric(c)) {
                try list.append(allocator, std.ascii.toLower(c));
            } else {
                // Replace spaces, punctuation, etc. with hyphen.
                try list.append(allocator, '-');
            }
        } else {
            // Non-ASCII, non-Cyrillic: skip.
        }
    }

    // Second pass: collapse multiple hyphens and trim.
    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    var prev_hyphen = true; // Start true to skip leading hyphens.
    for (list.items) |c| {
        if (c == '-') {
            if (!prev_hyphen) {
                try result.append(allocator, '-');
            }
            prev_hyphen = true;
        } else {
            try result.append(allocator, c);
            prev_hyphen = false;
        }
    }

    // Trim trailing hyphen.
    if (result.items.len > 0 and result.items[result.items.len - 1] == '-') {
        result.items.len -= 1;
    }

    // Append newline.
    try result.append(allocator, '\n');

    return result.toOwnedSlice(allocator);
}

/// Transliterate Cyrillic codepoints to Latin equivalents.
/// Returns null for non-Cyrillic codepoints.
fn transliterateCyrillic(cp: u21) ?[]const u8 {
    return switch (cp) {
        // Uppercase Cyrillic
        0x0410 => "A",
        0x0411 => "B",
        0x0412 => "V",
        0x0413 => "G",
        0x0414 => "D",
        0x0415 => "E",
        0x0416 => "Zh",
        0x0417 => "Z",
        0x0418 => "I",
        0x0419 => "Y",
        0x041A => "K",
        0x041B => "L",
        0x041C => "M",
        0x041D => "N",
        0x041E => "O",
        0x041F => "P",
        0x0420 => "R",
        0x0421 => "S",
        0x0422 => "T",
        0x0423 => "U",
        0x0424 => "F",
        0x0425 => "Kh",
        0x0426 => "Ts",
        0x0427 => "Ch",
        0x0428 => "Sh",
        0x0429 => "Shch",
        0x042A => "",  // Hard sign
        0x042B => "Y",
        0x042C => "",  // Soft sign
        0x042D => "E",
        0x042E => "Yu",
        0x042F => "Ya",
        // Lowercase Cyrillic
        0x0430 => "a",
        0x0431 => "b",
        0x0432 => "v",
        0x0433 => "g",
        0x0434 => "d",
        0x0435 => "e",
        0x0436 => "zh",
        0x0437 => "z",
        0x0438 => "i",
        0x0439 => "y",
        0x043A => "k",
        0x043B => "l",
        0x043C => "m",
        0x043D => "n",
        0x043E => "o",
        0x043F => "p",
        0x0440 => "r",
        0x0441 => "s",
        0x0442 => "t",
        0x0443 => "u",
        0x0444 => "f",
        0x0445 => "kh",
        0x0446 => "ts",
        0x0447 => "ch",
        0x0448 => "sh",
        0x0449 => "shch",
        0x044A => "",  // Hard sign
        0x044B => "y",
        0x044C => "",  // Soft sign
        0x044D => "e",
        0x044E => "yu",
        0x044F => "ya",
        // Ё/ё
        0x0401 => "Yo",
        0x0451 => "yo",
        else => null,
    };
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "slug",
    .description = "Convert text to a URL-friendly slug",
    .category = .encoding,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_slug_out.tmp";

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

test "slug basic text" {
    const output = try execWithInput("Hello World", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("hello-world", trimmed);
}

test "slug with special characters" {
    const output = try execWithInput("Hello, World! How are you?", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("hello-world-how-are-you", trimmed);
}

test "slug with numbers" {
    const output = try execWithInput("Version 2.0 Release", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("version-2-0-release", trimmed);
}

test "slug cyrillic transliteration" {
    const output = try execWithInput("Привет мир", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("privet-mir", trimmed);
}

test "slug mixed latin and cyrillic" {
    const output = try execWithInput("Hello Мир", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("hello-mir", trimmed);
}

test "slug collapses multiple hyphens" {
    const output = try execWithInput("hello   ---   world", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("hello-world", trimmed);
}

test "slug trims leading and trailing hyphens" {
    const output = try execWithInput("  hello world  ", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("hello-world", trimmed);
}

test "slug empty input" {
    const output = try execWithInput("", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("", trimmed);
}

test "slug already clean" {
    const output = try execWithInput("already-clean-slug", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("already-clean-slug", trimmed);
}

test "slug uppercase becomes lowercase" {
    const output = try execWithInput("UPPERCASE TEXT", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("uppercase-text", trimmed);
}

test "slug unknown subcommand" {
    const result = execWithInput("test", "reverse");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "slug command struct fields" {
    try std.testing.expectEqualStrings("slug", command.name);
    try std.testing.expectEqual(registry.Category.encoding, command.category);
    try std.testing.expectEqual(@as(usize, 0), command.subcommands.len);
}
