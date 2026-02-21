const std = @import("std");
const theme_mod = @import("../themes/theme.zig");
const tui = @import("../../core/tui.zig");

/// Multi-line text input component for data entry in the TUI.
pub const TextInput = struct {
    /// The text content as lines.
    lines: std.ArrayList([]u8),
    /// Cursor row position (0-based line index).
    cursor_row: usize,
    /// Cursor column position (0-based character index).
    cursor_col: usize,
    /// Scroll offset for vertical scrolling.
    scroll_offset: usize,
    /// Visible rows in the text area.
    visible_rows: u16,
    /// Width of the text area.
    width: u16,
    /// Title.
    title: []const u8,
    /// Allocator.
    allocator: std.mem.Allocator,

    fn emptyLine(_: std.mem.Allocator) []u8 {
        return @constCast(@as([]const u8, ""));
    }

    /// Initialize with an empty buffer.
    pub fn init(allocator: std.mem.Allocator, title: []const u8) TextInput {
        var lines = std.ArrayList([]u8){};
        lines.append(allocator, emptyLine(allocator)) catch {};
        return .{
            .lines = lines,
            .cursor_row = 0,
            .cursor_col = 0,
            .scroll_offset = 0,
            .visible_rows = 10,
            .width = 40,
            .title = title,
            .allocator = allocator,
        };
    }

    /// Free all allocated lines and the line list.
    pub fn deinit(self: *TextInput) void {
        for (self.lines.items) |line| {
            if (line.len > 0) {
                self.allocator.free(line);
            }
        }
        self.lines.deinit(self.allocator);
    }

    /// Number of lines in the content.
    pub fn lineCount(self: *const TextInput) usize {
        return self.lines.items.len;
    }

    /// Get the content as a single string (lines joined by newlines).
    /// Caller owns the returned memory.
    pub fn getContent(self: *const TextInput) ![]u8 {
        const num_lines = self.lines.items.len;
        if (num_lines == 0) {
            return self.allocator.alloc(u8, 0);
        }
        var total: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            total += line.len;
            if (i < num_lines - 1) total += 1;
        }
        const result = try self.allocator.alloc(u8, total);
        var pos: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            if (line.len > 0) {
                @memcpy(result[pos .. pos + line.len], line);
                pos += line.len;
            }
            if (i < num_lines - 1) {
                result[pos] = '\n';
                pos += 1;
            }
        }
        return result;
    }

    /// Set the content from a string (replacing everything).
    pub fn setContent(self: *TextInput, content: []const u8) !void {
        for (self.lines.items) |line| {
            if (line.len > 0) {
                self.allocator.free(line);
            }
        }
        self.lines.items.len = 0;

        var start: usize = 0;
        for (content, 0..) |c, i| {
            if (c == '\n') {
                const line_data = content[start..i];
                if (line_data.len > 0) {
                    const line = try self.allocator.alloc(u8, line_data.len);
                    @memcpy(line, line_data);
                    try self.lines.append(self.allocator, line);
                } else {
                    try self.lines.append(self.allocator, emptyLine(self.allocator));
                }
                start = i + 1;
            }
        }
        const line_data = content[start..];
        if (line_data.len > 0) {
            const line = try self.allocator.alloc(u8, line_data.len);
            @memcpy(line, line_data);
            try self.lines.append(self.allocator, line);
        } else {
            try self.lines.append(self.allocator, emptyLine(self.allocator));
        }

        self.cursor_row = 0;
        self.cursor_col = 0;
        self.scroll_offset = 0;
    }

    /// Clear all content.
    pub fn clear(self: *TextInput) void {
        for (self.lines.items) |line| {
            if (line.len > 0) {
                self.allocator.free(line);
            }
        }
        self.lines.items.len = 0;
        self.lines.append(self.allocator, emptyLine(self.allocator)) catch {};
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.scroll_offset = 0;
    }

    /// Insert a character at the cursor position.
    pub fn insertChar(self: *TextInput, c: u8) !void {
        if (self.lines.items.len == 0) return;
        const old_line = self.lines.items[self.cursor_row];
        const col = @min(self.cursor_col, old_line.len);
        const new_line = try self.allocator.alloc(u8, old_line.len + 1);
        if (col > 0) @memcpy(new_line[0..col], old_line[0..col]);
        new_line[col] = c;
        if (col < old_line.len) @memcpy(new_line[col + 1 ..], old_line[col..]);
        if (old_line.len > 0) self.allocator.free(old_line);
        self.lines.items[self.cursor_row] = new_line;
        self.cursor_col = col + 1;
    }

    /// Delete the character before the cursor (backspace).
    pub fn deleteBack(self: *TextInput) !void {
        if (self.lines.items.len == 0) return;
        if (self.cursor_col > 0) {
            const old_line = self.lines.items[self.cursor_row];
            const col = @min(self.cursor_col, old_line.len);
            if (old_line.len <= 1) {
                if (old_line.len > 0) self.allocator.free(old_line);
                self.lines.items[self.cursor_row] = emptyLine(self.allocator);
                self.cursor_col = 0;
                return;
            }
            const new_line = try self.allocator.alloc(u8, old_line.len - 1);
            if (col > 1) @memcpy(new_line[0 .. col - 1], old_line[0 .. col - 1]);
            if (col < old_line.len) @memcpy(new_line[col - 1 ..], old_line[col..]);
            self.allocator.free(old_line);
            self.lines.items[self.cursor_row] = new_line;
            self.cursor_col = col - 1;
        } else if (self.cursor_row > 0) {
            const curr_line = self.lines.items[self.cursor_row];
            const prev_line = self.lines.items[self.cursor_row - 1];
            const merged = try self.allocator.alloc(u8, prev_line.len + curr_line.len);
            if (prev_line.len > 0) @memcpy(merged[0..prev_line.len], prev_line);
            if (curr_line.len > 0) @memcpy(merged[prev_line.len..], curr_line);
            const new_col = prev_line.len;
            if (prev_line.len > 0) self.allocator.free(prev_line);
            if (curr_line.len > 0) self.allocator.free(curr_line);
            self.lines.items[self.cursor_row - 1] = merged;
            _ = self.lines.orderedRemove(self.cursor_row);
            self.cursor_row -= 1;
            self.cursor_col = new_col;
            self.ensureCursorVisible();
        }
    }

    /// Insert a newline at the cursor position.
    pub fn insertNewline(self: *TextInput) !void {
        if (self.lines.items.len == 0) return;
        const old_line = self.lines.items[self.cursor_row];
        const col = @min(self.cursor_col, old_line.len);

        const before = try self.allocator.alloc(u8, col);
        errdefer if (before.len > 0) self.allocator.free(before);
        if (col > 0) @memcpy(before, old_line[0..col]);
        const after = try self.allocator.alloc(u8, old_line.len - col);
        if (old_line.len > col) @memcpy(after, old_line[col..]);

        // Do the fallible insert before irreversible state changes.
        try self.lines.insert(self.allocator, self.cursor_row + 1, after);
        // All allocations succeeded; commit non-fallible changes.
        if (old_line.len > 0) self.allocator.free(old_line);
        self.lines.items[self.cursor_row] = before;
        self.cursor_row += 1;
        self.cursor_col = 0;
        self.ensureCursorVisible();
    }

    /// Delete the current line (Ctrl+K).
    pub fn deleteLine(self: *TextInput) void {
        if (self.lines.items.len <= 1) {
            const line = self.lines.items[0];
            if (line.len > 0) self.allocator.free(line);
            self.lines.items[0] = emptyLine(self.allocator);
            self.cursor_col = 0;
            return;
        }
        const line = self.lines.items[self.cursor_row];
        if (line.len > 0) self.allocator.free(line);
        _ = self.lines.orderedRemove(self.cursor_row);
        if (self.cursor_row >= self.lines.items.len) {
            self.cursor_row = self.lines.items.len - 1;
        }
        self.cursor_col = @min(self.cursor_col, self.lines.items[self.cursor_row].len);
        self.ensureCursorVisible();
    }

    /// Move cursor left.
    pub fn moveCursorLeft(self: *TextInput) void {
        if (self.cursor_col > 0) {
            self.cursor_col -= 1;
        } else if (self.cursor_row > 0) {
            self.cursor_row -= 1;
            self.cursor_col = self.lines.items[self.cursor_row].len;
            self.ensureCursorVisible();
        }
    }

    /// Move cursor right.
    pub fn moveCursorRight(self: *TextInput) void {
        if (self.lines.items.len == 0) return;
        const line_len = self.lines.items[self.cursor_row].len;
        if (self.cursor_col < line_len) {
            self.cursor_col += 1;
        } else if (self.cursor_row < self.lines.items.len - 1) {
            self.cursor_row += 1;
            self.cursor_col = 0;
            self.ensureCursorVisible();
        }
    }

    /// Move cursor up.
    pub fn moveCursorUp(self: *TextInput) void {
        if (self.cursor_row > 0) {
            self.cursor_row -= 1;
            self.cursor_col = @min(self.cursor_col, self.lines.items[self.cursor_row].len);
            self.ensureCursorVisible();
        }
    }

    /// Move cursor down.
    pub fn moveCursorDown(self: *TextInput) void {
        if (self.cursor_row < self.lines.items.len - 1) {
            self.cursor_row += 1;
            self.cursor_col = @min(self.cursor_col, self.lines.items[self.cursor_row].len);
            self.ensureCursorVisible();
        }
    }

    /// Move cursor to start of line.
    pub fn moveCursorHome(self: *TextInput) void {
        self.cursor_col = 0;
    }

    /// Move cursor to end of line.
    pub fn moveCursorEnd(self: *TextInput) void {
        if (self.lines.items.len == 0) return;
        self.cursor_col = self.lines.items[self.cursor_row].len;
    }

    /// Ensure the cursor is within the visible area.
    fn ensureCursorVisible(self: *TextInput) void {
        if (self.cursor_row < self.scroll_offset) {
            self.scroll_offset = self.cursor_row;
        }
        if (self.cursor_row >= self.scroll_offset + self.visible_rows) {
            self.scroll_offset = self.cursor_row - self.visible_rows + 1;
        }
    }

    /// Render the text input to the given writer.
    pub fn render(self: *const TextInput, writer: anytype, start_row: u16, start_col: u16, colors: theme_mod.ColorScheme, is_active: bool) !void {
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
        const end_line = @min(self.scroll_offset + self.visible_rows, self.lines.items.len);
        for (self.lines.items[self.scroll_offset..end_line]) |line| {
            try tui.Screen.moveTo(writer, row, start_col);
            try border_color.apply(writer);
            try writer.writeAll("\xe2\x94\x82"); // │
            try theme_mod.Color.reset(writer);

            try colors.input.apply(writer);
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
    pub fn handleKey(self: *TextInput, key: tui.Key) !bool {
        switch (key) {
            .char => |c| {
                if (c >= 0x20 and c < 0x7F) {
                    try self.insertChar(c);
                    return true;
                }
                return false;
            },
            .enter => {
                try self.insertNewline();
                return true;
            },
            .backspace => {
                try self.deleteBack();
                return true;
            },
            .arrow_left => {
                self.moveCursorLeft();
                return true;
            },
            .arrow_right => {
                self.moveCursorRight();
                return true;
            },
            .arrow_up => {
                self.moveCursorUp();
                return true;
            },
            .arrow_down => {
                self.moveCursorDown();
                return true;
            },
            .home, .ctrl_a => {
                self.moveCursorHome();
                return true;
            },
            .end, .ctrl_e => {
                self.moveCursorEnd();
                return true;
            },
            .ctrl_k => {
                self.deleteLine();
                return true;
            },
            .ctrl_u => {
                self.clear();
                return true;
            },
            else => return false,
        }
    }

    /// Total height needed (title + content + bottom border).
    pub fn totalHeight(self: *const TextInput) u16 {
        return self.visible_rows + 2;
    }
};

// --- Tests ---

test "TextInput init and deinit" {
    var ti = TextInput.init(std.testing.allocator, "Input");
    defer ti.deinit();
    try std.testing.expectEqual(@as(usize, 1), ti.lineCount());
    try std.testing.expectEqual(@as(usize, 0), ti.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), ti.cursor_col);
}

test "TextInput insertChar" {
    var ti = TextInput.init(std.testing.allocator, "");
    defer ti.deinit();
    try ti.insertChar('H');
    try ti.insertChar('i');
    const content = try ti.getContent();
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("Hi", content);
    try std.testing.expectEqual(@as(usize, 2), ti.cursor_col);
}

test "TextInput setContent" {
    var ti = TextInput.init(std.testing.allocator, "");
    defer ti.deinit();
    try ti.setContent("line1\nline2\nline3");
    try std.testing.expectEqual(@as(usize, 3), ti.lineCount());
    const content = try ti.getContent();
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("line1\nline2\nline3", content);
}

test "TextInput deleteBack in middle of line" {
    var ti = TextInput.init(std.testing.allocator, "");
    defer ti.deinit();
    try ti.setContent("abc");
    ti.cursor_col = 2;
    try ti.deleteBack();
    const content = try ti.getContent();
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("ac", content);
    try std.testing.expectEqual(@as(usize, 1), ti.cursor_col);
}

test "TextInput deleteBack at start of line merges with previous" {
    var ti = TextInput.init(std.testing.allocator, "");
    defer ti.deinit();
    try ti.setContent("ab\ncd");
    ti.cursor_row = 1;
    ti.cursor_col = 0;
    try ti.deleteBack();
    try std.testing.expectEqual(@as(usize, 1), ti.lineCount());
    const content = try ti.getContent();
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("abcd", content);
    try std.testing.expectEqual(@as(usize, 0), ti.cursor_row);
    try std.testing.expectEqual(@as(usize, 2), ti.cursor_col);
}

test "TextInput insertNewline splits line" {
    var ti = TextInput.init(std.testing.allocator, "");
    defer ti.deinit();
    try ti.setContent("abcd");
    ti.cursor_col = 2;
    try ti.insertNewline();
    try std.testing.expectEqual(@as(usize, 2), ti.lineCount());
    const content = try ti.getContent();
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("ab\ncd", content);
    try std.testing.expectEqual(@as(usize, 1), ti.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), ti.cursor_col);
}

test "TextInput cursor movement" {
    var ti = TextInput.init(std.testing.allocator, "");
    defer ti.deinit();
    try ti.setContent("abc\ndef");
    ti.cursor_row = 0;
    ti.cursor_col = 1;

    ti.moveCursorRight();
    try std.testing.expectEqual(@as(usize, 2), ti.cursor_col);

    ti.moveCursorLeft();
    try std.testing.expectEqual(@as(usize, 1), ti.cursor_col);

    ti.moveCursorDown();
    try std.testing.expectEqual(@as(usize, 1), ti.cursor_row);

    ti.moveCursorUp();
    try std.testing.expectEqual(@as(usize, 0), ti.cursor_row);

    ti.moveCursorEnd();
    try std.testing.expectEqual(@as(usize, 3), ti.cursor_col);

    ti.moveCursorHome();
    try std.testing.expectEqual(@as(usize, 0), ti.cursor_col);
}

test "TextInput clear resets everything" {
    var ti = TextInput.init(std.testing.allocator, "");
    defer ti.deinit();
    try ti.setContent("some\nmultiline\ntext");
    ti.clear();
    try std.testing.expectEqual(@as(usize, 1), ti.lineCount());
    try std.testing.expectEqual(@as(usize, 0), ti.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), ti.cursor_col);
    const content = try ti.getContent();
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("", content);
}

test "TextInput deleteLine" {
    var ti = TextInput.init(std.testing.allocator, "");
    defer ti.deinit();
    try ti.setContent("line1\nline2\nline3");
    ti.cursor_row = 1;
    ti.deleteLine();
    try std.testing.expectEqual(@as(usize, 2), ti.lineCount());
    const content = try ti.getContent();
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("line1\nline3", content);
}

test "TextInput handleKey processes chars" {
    var ti = TextInput.init(std.testing.allocator, "");
    defer ti.deinit();
    const consumed = try ti.handleKey(.{ .char = 'x' });
    try std.testing.expect(consumed);
    const content = try ti.getContent();
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("x", content);
}

test "TextInput handleKey ignores unrelated keys" {
    var ti = TextInput.init(std.testing.allocator, "");
    defer ti.deinit();
    try std.testing.expect(!try ti.handleKey(.f1));
    try std.testing.expect(!try ti.handleKey(.escape));
}

test "TextInput totalHeight" {
    var ti = TextInput.init(std.testing.allocator, "");
    defer ti.deinit();
    ti.visible_rows = 8;
    try std.testing.expectEqual(@as(u16, 10), ti.totalHeight());
}

test "TextInput cursor wraps between lines" {
    var ti = TextInput.init(std.testing.allocator, "");
    defer ti.deinit();
    try ti.setContent("ab\ncd");
    ti.cursor_row = 0;
    ti.cursor_col = 2;
    ti.moveCursorRight(); // should wrap to next line
    try std.testing.expectEqual(@as(usize, 1), ti.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), ti.cursor_col);
    ti.moveCursorLeft(); // should wrap back
    try std.testing.expectEqual(@as(usize, 0), ti.cursor_row);
    try std.testing.expectEqual(@as(usize, 2), ti.cursor_col);
}
