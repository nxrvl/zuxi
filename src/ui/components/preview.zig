const std = @import("std");
const theme_mod = @import("../themes/theme.zig");
const tui = @import("../../core/tui.zig");

/// Read-only output preview component with scrolling.
/// Used to display command output or live preview of transformations.
pub const Preview = struct {
    /// Content lines to display.
    lines: []const []const u8,
    /// Vertical scroll offset.
    scroll_offset: usize,
    /// Number of visible rows.
    visible_rows: u16,
    /// Width of the preview area.
    width: u16,
    /// Title.
    title: []const u8,

    /// Create a new preview component.
    pub fn init(title: []const u8) Preview {
        return .{
            .lines = &.{},
            .scroll_offset = 0,
            .visible_rows = 10,
            .width = 40,
            .title = title,
        };
    }

    /// Set the content to display. The content string is split by newlines.
    /// The caller must ensure the content/lines slice outlives the preview.
    pub fn setLines(self: *Preview, lines: []const []const u8) void {
        self.lines = lines;
        self.scroll_offset = 0;
    }

    /// Scroll up by one line.
    pub fn scrollUp(self: *Preview) void {
        if (self.scroll_offset > 0) {
            self.scroll_offset -= 1;
        }
    }

    /// Scroll down by one line.
    pub fn scrollDown(self: *Preview) void {
        if (self.lines.len > self.visible_rows and
            self.scroll_offset < self.lines.len - self.visible_rows)
        {
            self.scroll_offset += 1;
        }
    }

    /// Scroll up by one page.
    pub fn scrollPageUp(self: *Preview) void {
        if (self.scroll_offset >= self.visible_rows) {
            self.scroll_offset -= self.visible_rows;
        } else {
            self.scroll_offset = 0;
        }
    }

    /// Scroll down by one page.
    pub fn scrollPageDown(self: *Preview) void {
        if (self.lines.len <= self.visible_rows) return;
        const max_offset = self.lines.len - self.visible_rows;
        if (self.scroll_offset + self.visible_rows <= max_offset) {
            self.scroll_offset += self.visible_rows;
        } else {
            self.scroll_offset = max_offset;
        }
    }

    /// Scroll to the top.
    pub fn scrollToTop(self: *Preview) void {
        self.scroll_offset = 0;
    }

    /// Scroll to the bottom.
    pub fn scrollToBottom(self: *Preview) void {
        if (self.lines.len > self.visible_rows) {
            self.scroll_offset = self.lines.len - self.visible_rows;
        }
    }

    /// Render the preview to the given writer.
    pub fn render(self: *const Preview, writer: anytype, start_row: u16, start_col: u16, colors: theme_mod.ColorScheme, is_active: bool) !void {
        const border_color = if (is_active) colors.border_active else colors.border_inactive;
        const inner_width: usize = if (self.width > 2) self.width - 2 else 0;

        // Title bar.
        try tui.Screen.moveTo(writer, start_row, start_col);
        try border_color.apply(writer);
        try writer.writeAll("\xe2\x94\x8c"); // ┌
        if (self.title.len > 0) {
            const title_len = @min(self.title.len, inner_width);
            try writer.writeAll(self.title[0..title_len]);
            var pad: usize = inner_width - title_len;
            while (pad > 0) : (pad -= 1) {
                try writer.writeAll("\xe2\x94\x80"); // ─
            }
        } else {
            var i: usize = 0;
            while (i < inner_width) : (i += 1) {
                try writer.writeAll("\xe2\x94\x80"); // ─
            }
        }
        try writer.writeAll("\xe2\x94\x90"); // ┐
        try theme_mod.Color.reset(writer);

        // Content rows.
        var row: u16 = start_row + 1;
        const end_line = @min(self.scroll_offset + self.visible_rows, self.lines.len);
        for (self.lines[self.scroll_offset..end_line]) |line| {
            try tui.Screen.moveTo(writer, row, start_col);
            try border_color.apply(writer);
            try writer.writeAll("\xe2\x94\x82"); // │
            try theme_mod.Color.reset(writer);

            try colors.preview.apply(writer);
            const display_len = @min(line.len, inner_width);
            if (display_len > 0) try writer.writeAll(line[0..display_len]);
            var pad_count: usize = inner_width - display_len;
            while (pad_count > 0) : (pad_count -= 1) {
                try writer.writeAll(" ");
            }
            try theme_mod.Color.reset(writer);

            try border_color.apply(writer);
            try writer.writeAll("\xe2\x94\x82"); // │
            try theme_mod.Color.reset(writer);
            row += 1;
        }

        // Empty rows.
        while (row < start_row + 1 + self.visible_rows) : (row += 1) {
            try tui.Screen.moveTo(writer, row, start_col);
            try border_color.apply(writer);
            try writer.writeAll("\xe2\x94\x82"); // │
            try theme_mod.Color.reset(writer);
            var pad_count: usize = inner_width;
            while (pad_count > 0) : (pad_count -= 1) {
                try writer.writeAll(" ");
            }
            try border_color.apply(writer);
            try writer.writeAll("\xe2\x94\x82"); // │
            try theme_mod.Color.reset(writer);
        }

        // Scroll indicator.
        if (self.lines.len > self.visible_rows) {
            // Show a simple scroll position indicator on the right border.
            const total = self.lines.len - self.visible_rows;
            const indicator_row: u16 = if (total > 0)
                start_row + 1 + @as(u16, @intCast(@min(
                    self.scroll_offset * (self.visible_rows - 1) / total,
                    self.visible_rows - 1,
                )))
            else
                start_row + 1;
            try tui.Screen.moveTo(writer, indicator_row, start_col + self.width - 1);
            try colors.highlight.apply(writer);
            try writer.writeAll("\xe2\x96\x88"); // █
            try theme_mod.Color.reset(writer);
        }

        // Bottom border.
        try tui.Screen.moveTo(writer, row, start_col);
        try border_color.apply(writer);
        try writer.writeAll("\xe2\x94\x94"); // └
        {
            var i: usize = 0;
            while (i < inner_width) : (i += 1) {
                try writer.writeAll("\xe2\x94\x80"); // ─
            }
        }
        try writer.writeAll("\xe2\x94\x98"); // ┘
        try theme_mod.Color.reset(writer);
    }

    /// Handle a key event. Returns true if consumed.
    pub fn handleKey(self: *Preview, key: tui.Key) bool {
        switch (key) {
            .arrow_up => {
                self.scrollUp();
                return true;
            },
            .arrow_down => {
                self.scrollDown();
                return true;
            },
            .page_up => {
                self.scrollPageUp();
                return true;
            },
            .page_down => {
                self.scrollPageDown();
                return true;
            },
            .home => {
                self.scrollToTop();
                return true;
            },
            .end => {
                self.scrollToBottom();
                return true;
            },
            else => return false,
        }
    }

    /// Total height needed (title + content + bottom border).
    pub fn totalHeight(self: *const Preview) u16 {
        return self.visible_rows + 2;
    }
};

// --- Tests ---

test "Preview init" {
    const p = Preview.init("Output");
    try std.testing.expectEqual(@as(usize, 0), p.lines.len);
    try std.testing.expectEqual(@as(usize, 0), p.scroll_offset);
    try std.testing.expectEqualStrings("Output", p.title);
}

test "Preview setLines" {
    var p = Preview.init("");
    const lines = [_][]const u8{ "line1", "line2", "line3" };
    p.setLines(&lines);
    try std.testing.expectEqual(@as(usize, 3), p.lines.len);
    try std.testing.expectEqual(@as(usize, 0), p.scroll_offset);
}

test "Preview scrollDown and scrollUp" {
    var p = Preview.init("");
    var lines_buf: [20][]const u8 = undefined;
    for (&lines_buf) |*line| {
        line.* = "text";
    }
    p.setLines(&lines_buf);
    p.visible_rows = 5;

    p.scrollDown();
    try std.testing.expectEqual(@as(usize, 1), p.scroll_offset);
    p.scrollDown();
    try std.testing.expectEqual(@as(usize, 2), p.scroll_offset);

    p.scrollUp();
    try std.testing.expectEqual(@as(usize, 1), p.scroll_offset);
    p.scrollUp();
    try std.testing.expectEqual(@as(usize, 0), p.scroll_offset);
    p.scrollUp(); // should not go negative
    try std.testing.expectEqual(@as(usize, 0), p.scroll_offset);
}

test "Preview scrollDown does not exceed max" {
    var p = Preview.init("");
    const lines = [_][]const u8{ "a", "b", "c", "d", "e" };
    p.setLines(&lines);
    p.visible_rows = 3;

    // max scroll = 5 - 3 = 2
    p.scrollDown();
    p.scrollDown();
    p.scrollDown(); // should stay at 2
    try std.testing.expectEqual(@as(usize, 2), p.scroll_offset);
}

test "Preview scrollPageUp and scrollPageDown" {
    var p = Preview.init("");
    var lines_buf: [30][]const u8 = undefined;
    for (&lines_buf) |*line| {
        line.* = "text";
    }
    p.setLines(&lines_buf);
    p.visible_rows = 10;

    p.scrollPageDown();
    try std.testing.expectEqual(@as(usize, 10), p.scroll_offset);
    p.scrollPageDown();
    try std.testing.expectEqual(@as(usize, 20), p.scroll_offset);
    p.scrollPageDown(); // max = 30-10 = 20
    try std.testing.expectEqual(@as(usize, 20), p.scroll_offset);

    p.scrollPageUp();
    try std.testing.expectEqual(@as(usize, 10), p.scroll_offset);
    p.scrollPageUp();
    try std.testing.expectEqual(@as(usize, 0), p.scroll_offset);
}

test "Preview scrollToTop and scrollToBottom" {
    var p = Preview.init("");
    const lines = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" };
    p.setLines(&lines);
    p.visible_rows = 3;

    p.scrollToBottom();
    try std.testing.expectEqual(@as(usize, 7), p.scroll_offset);
    p.scrollToTop();
    try std.testing.expectEqual(@as(usize, 0), p.scroll_offset);
}

test "Preview handleKey consumes scroll keys" {
    var p = Preview.init("");
    var lines_buf: [10][]const u8 = undefined;
    for (&lines_buf) |*line| {
        line.* = "text";
    }
    p.setLines(&lines_buf);
    p.visible_rows = 5;

    try std.testing.expect(p.handleKey(.arrow_down));
    try std.testing.expectEqual(@as(usize, 1), p.scroll_offset);
    try std.testing.expect(p.handleKey(.arrow_up));
    try std.testing.expectEqual(@as(usize, 0), p.scroll_offset);
    try std.testing.expect(p.handleKey(.page_down));
    try std.testing.expect(p.handleKey(.home));
    try std.testing.expectEqual(@as(usize, 0), p.scroll_offset);
}

test "Preview handleKey ignores unrelated keys" {
    var p = Preview.init("");
    try std.testing.expect(!p.handleKey(.enter));
    try std.testing.expect(!p.handleKey(.tab));
    try std.testing.expect(!p.handleKey(.{ .char = 'a' }));
}

test "Preview totalHeight" {
    var p = Preview.init("");
    p.visible_rows = 15;
    try std.testing.expectEqual(@as(u16, 17), p.totalHeight());
}

test "Preview empty content scroll does not crash" {
    var p = Preview.init("");
    p.scrollUp();
    p.scrollDown();
    p.scrollPageUp();
    p.scrollPageDown();
    p.scrollToTop();
    p.scrollToBottom();
    try std.testing.expectEqual(@as(usize, 0), p.scroll_offset);
}

test "Preview few lines do not scroll" {
    var p = Preview.init("");
    const lines = [_][]const u8{ "a", "b" };
    p.setLines(&lines);
    p.visible_rows = 5;
    p.scrollDown(); // should not scroll since 2 < 5
    try std.testing.expectEqual(@as(usize, 0), p.scroll_offset);
}
