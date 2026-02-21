const std = @import("std");

/// ANSI color codes for terminal rendering.
pub const Color = struct {
    fg: ?[]const u8 = null,
    bg: ?[]const u8 = null,

    /// Write the ANSI escape sequence to set this color.
    pub fn apply(self: Color, writer: anytype) !void {
        if (self.bg) |bg| try writer.writeAll(bg);
        if (self.fg) |fg| try writer.writeAll(fg);
    }

    /// Write the ANSI reset sequence.
    pub fn reset(writer: anytype) !void {
        try writer.writeAll("\x1b[0m");
    }
};

/// Named color slots used by TUI components.
pub const ColorScheme = struct {
    /// Normal text.
    text: Color,
    /// Dimmed/secondary text.
    text_dim: Color,
    /// Highlighted/selected item.
    highlight: Color,
    /// Active/focused panel border.
    border_active: Color,
    /// Inactive panel border.
    border_inactive: Color,
    /// Category header text.
    header: Color,
    /// Status bar.
    status_bar: Color,
    /// Error text.
    err: Color,
    /// Input area text.
    input: Color,
    /// Preview area text.
    preview: Color,
};

/// Available theme variants.
pub const ThemeVariant = enum {
    dark,
    light,
};

/// Theme state that can be toggled at runtime.
pub const Theme = struct {
    variant: ThemeVariant,
    colors: ColorScheme,

    /// Toggle between dark and light themes. Returns the new theme.
    pub fn toggle(self: Theme) Theme {
        return switch (self.variant) {
            .dark => light_theme,
            .light => dark_theme,
        };
    }

    /// Get the display name of the current theme.
    pub fn name(self: Theme) []const u8 {
        return switch (self.variant) {
            .dark => "Dark",
            .light => "Light",
        };
    }
};

// ANSI escape code helpers.
const ESC = "\x1b[";

// Foreground colors.
const FG_WHITE = ESC ++ "37m";
const FG_BLACK = ESC ++ "30m";
const FG_GRAY = ESC ++ "90m";
const FG_BRIGHT_WHITE = ESC ++ "97m";
const FG_CYAN = ESC ++ "36m";
const FG_BRIGHT_CYAN = ESC ++ "96m";
const FG_YELLOW = ESC ++ "33m";
const FG_RED = ESC ++ "31m";
const FG_BRIGHT_RED = ESC ++ "91m";
const FG_GREEN = ESC ++ "32m";
const FG_BRIGHT_GREEN = ESC ++ "92m";
const FG_BLUE = ESC ++ "34m";
const FG_BRIGHT_BLUE = ESC ++ "94m";
const FG_MAGENTA = ESC ++ "35m";

// Background colors.
const BG_BLACK = ESC ++ "40m";
const BG_WHITE = ESC ++ "47m";
const BG_BRIGHT_BLACK = ESC ++ "100m";
const BG_DARK_GRAY = ESC ++ "48;5;236m";
const BG_LIGHT_GRAY = ESC ++ "48;5;253m";
const BG_BLUE = ESC ++ "44m";
const BG_BRIGHT_BLUE = ESC ++ "104m";

/// Default dark theme.
pub const dark_theme = Theme{
    .variant = .dark,
    .colors = .{
        .text = .{ .fg = FG_WHITE },
        .text_dim = .{ .fg = FG_GRAY },
        .highlight = .{ .fg = FG_BRIGHT_WHITE, .bg = BG_BLUE },
        .border_active = .{ .fg = FG_BRIGHT_CYAN },
        .border_inactive = .{ .fg = FG_GRAY },
        .header = .{ .fg = FG_YELLOW },
        .status_bar = .{ .fg = FG_BLACK, .bg = BG_BRIGHT_BLACK },
        .err = .{ .fg = FG_BRIGHT_RED },
        .input = .{ .fg = FG_BRIGHT_GREEN },
        .preview = .{ .fg = FG_WHITE },
    },
};

/// Default light theme.
pub const light_theme = Theme{
    .variant = .light,
    .colors = .{
        .text = .{ .fg = FG_BLACK },
        .text_dim = .{ .fg = FG_GRAY },
        .highlight = .{ .fg = FG_BRIGHT_WHITE, .bg = BG_BRIGHT_BLUE },
        .border_active = .{ .fg = FG_BLUE },
        .border_inactive = .{ .fg = FG_GRAY },
        .header = .{ .fg = FG_MAGENTA },
        .status_bar = .{ .fg = FG_WHITE, .bg = BG_LIGHT_GRAY },
        .err = .{ .fg = FG_RED },
        .input = .{ .fg = FG_GREEN },
        .preview = .{ .fg = FG_BLACK },
    },
};

// --- Tests ---

test "dark theme has correct variant" {
    try std.testing.expectEqual(ThemeVariant.dark, dark_theme.variant);
}

test "light theme has correct variant" {
    try std.testing.expectEqual(ThemeVariant.light, light_theme.variant);
}

test "toggle dark to light" {
    const result = dark_theme.toggle();
    try std.testing.expectEqual(ThemeVariant.light, result.variant);
}

test "toggle light to dark" {
    const result = light_theme.toggle();
    try std.testing.expectEqual(ThemeVariant.dark, result.variant);
}

test "toggle is reversible" {
    const result = dark_theme.toggle().toggle();
    try std.testing.expectEqual(ThemeVariant.dark, result.variant);
}

test "theme name returns correct string" {
    try std.testing.expectEqualStrings("Dark", dark_theme.name());
    try std.testing.expectEqualStrings("Light", light_theme.name());
}

test "dark theme colors are all populated" {
    const c = dark_theme.colors;
    try std.testing.expect(c.text.fg != null);
    try std.testing.expect(c.text_dim.fg != null);
    try std.testing.expect(c.highlight.fg != null);
    try std.testing.expect(c.highlight.bg != null);
    try std.testing.expect(c.border_active.fg != null);
    try std.testing.expect(c.border_inactive.fg != null);
    try std.testing.expect(c.header.fg != null);
    try std.testing.expect(c.status_bar.fg != null);
    try std.testing.expect(c.status_bar.bg != null);
    try std.testing.expect(c.err.fg != null);
    try std.testing.expect(c.input.fg != null);
    try std.testing.expect(c.preview.fg != null);
}

test "light theme colors are all populated" {
    const c = light_theme.colors;
    try std.testing.expect(c.text.fg != null);
    try std.testing.expect(c.text_dim.fg != null);
    try std.testing.expect(c.highlight.fg != null);
    try std.testing.expect(c.highlight.bg != null);
    try std.testing.expect(c.border_active.fg != null);
    try std.testing.expect(c.border_inactive.fg != null);
    try std.testing.expect(c.header.fg != null);
    try std.testing.expect(c.status_bar.fg != null);
    try std.testing.expect(c.err.fg != null);
    try std.testing.expect(c.input.fg != null);
    try std.testing.expect(c.preview.fg != null);
}

test "color apply writes escape sequences" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const color = Color{ .fg = FG_RED, .bg = BG_BLACK };
    try color.apply(fbs.writer());
    const written = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[") != null);
    try std.testing.expect(written.len > 0);
}

test "color reset writes reset sequence" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Color.reset(fbs.writer());
    try std.testing.expectEqualStrings("\x1b[0m", fbs.getWritten());
}

test "dark and light themes have different highlight backgrounds" {
    try std.testing.expect(!std.mem.eql(
        u8,
        dark_theme.colors.highlight.bg.?,
        light_theme.colors.highlight.bg.?,
    ));
}
