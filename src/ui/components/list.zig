const std = @import("std");
const theme_mod = @import("../themes/theme.zig");
const tui = @import("../../core/tui.zig");

/// A scrollable list component with highlighted selection.
/// Used for category and command navigation in the TUI.
pub const List = struct {
    /// Items to display.
    items: []const ListItem,
    /// Currently selected index.
    selected: usize,
    /// Scroll offset (first visible item index).
    scroll_offset: usize,
    /// Number of visible rows available for items.
    visible_rows: u16,
    /// Width of the list area in columns.
    width: u16,
    /// Title displayed at the top.
    title: []const u8,

    pub const ListItem = struct {
        label: []const u8,
        description: []const u8,
        category: []const u8,
    };

    /// Create a new list with the given items.
    pub fn init(items: []const ListItem, title: []const u8) List {
        return .{
            .items = items,
            .selected = 0,
            .scroll_offset = 0,
            .visible_rows = 20,
            .width = 30,
            .title = title,
        };
    }

    /// Move selection up by one.
    pub fn moveUp(self: *List) void {
        if (self.items.len == 0) return;
        if (self.selected > 0) {
            self.selected -= 1;
            if (self.selected < self.scroll_offset) {
                self.scroll_offset = self.selected;
            }
        }
    }

    /// Move selection down by one.
    pub fn moveDown(self: *List) void {
        if (self.items.len == 0) return;
        if (self.selected < self.items.len - 1) {
            self.selected += 1;
            if (self.selected >= self.scroll_offset + self.visible_rows) {
                self.scroll_offset = self.selected - self.visible_rows + 1;
            }
        }
    }

    /// Move selection up by one page.
    pub fn pageUp(self: *List) void {
        if (self.items.len == 0) return;
        const page = self.visible_rows;
        if (self.selected >= page) {
            self.selected -= page;
        } else {
            self.selected = 0;
        }
        if (self.scroll_offset >= page) {
            self.scroll_offset -= page;
        } else {
            self.scroll_offset = 0;
        }
    }

    /// Move selection down by one page.
    pub fn pageDown(self: *List) void {
        if (self.items.len == 0) return;
        const page = self.visible_rows;
        if (self.selected + page < self.items.len) {
            self.selected += page;
        } else {
            self.selected = self.items.len - 1;
        }
        const max_offset = if (self.items.len > self.visible_rows)
            self.items.len - self.visible_rows
        else
            0;
        if (self.scroll_offset + page <= max_offset) {
            self.scroll_offset += page;
        } else {
            self.scroll_offset = max_offset;
        }
    }

    /// Jump to the first item.
    pub fn goToStart(self: *List) void {
        self.selected = 0;
        self.scroll_offset = 0;
    }

    /// Jump to the last item.
    pub fn goToEnd(self: *List) void {
        if (self.items.len == 0) return;
        self.selected = self.items.len - 1;
        if (self.items.len > self.visible_rows) {
            self.scroll_offset = self.items.len - self.visible_rows;
        }
    }

    /// Get the currently selected item, or null if the list is empty.
    pub fn getSelected(self: *const List) ?ListItem {
        if (self.items.len == 0) return null;
        return self.items[self.selected];
    }

    /// Render the list to the given writer at the specified position.
    pub fn render(self: *const List, writer: anytype, start_row: u16, start_col: u16, colors: theme_mod.ColorScheme, is_active: bool) !void {
        // Draw title bar.
        try tui.Screen.moveTo(writer, start_row, start_col);
        if (is_active) {
            try colors.border_active.apply(writer);
        } else {
            try colors.border_inactive.apply(writer);
        }
        try writer.writeAll("\xe2\x94\x8c"); // ┌
        const title_space = if (self.width > 2) self.width - 2 else 0;
        if (self.title.len > 0) {
            const title_len = @min(self.title.len, title_space);
            try writer.writeAll(self.title[0..title_len]);
            var pad: u16 = @intCast(title_space -| title_len);
            while (pad > 0) : (pad -= 1) {
                try writer.writeAll("\xe2\x94\x80"); // ─
            }
        } else {
            var i: u16 = 0;
            while (i < title_space) : (i += 1) {
                try writer.writeAll("\xe2\x94\x80"); // ─
            }
        }
        try writer.writeAll("\xe2\x94\x90"); // ┐
        try theme_mod.Color.reset(writer);

        // Draw items.
        const end_idx = @min(self.scroll_offset + self.visible_rows, self.items.len);
        var row: u16 = start_row + 1;
        for (self.items[self.scroll_offset..end_idx], self.scroll_offset..) |item, idx| {
            try tui.Screen.moveTo(writer, row, start_col);
            if (is_active) {
                try colors.border_active.apply(writer);
            } else {
                try colors.border_inactive.apply(writer);
            }
            try writer.writeAll("\xe2\x94\x82"); // │
            try theme_mod.Color.reset(writer);

            const content_width = if (self.width > 2) self.width - 2 else 0;

            if (idx == self.selected) {
                try colors.highlight.apply(writer);
            } else {
                try colors.text.apply(writer);
            }

            // Write label, truncated or padded to content_width.
            const label_len = @min(item.label.len, content_width);
            try writer.writeAll(item.label[0..label_len]);
            if (label_len < content_width) {
                var pad_count: usize = content_width - label_len;
                while (pad_count > 0) : (pad_count -= 1) {
                    try writer.writeAll(" ");
                }
            }
            try theme_mod.Color.reset(writer);

            if (is_active) {
                try colors.border_active.apply(writer);
            } else {
                try colors.border_inactive.apply(writer);
            }
            try writer.writeAll("\xe2\x94\x82"); // │
            try theme_mod.Color.reset(writer);

            row += 1;
        }

        // Fill empty rows.
        while (row < start_row + 1 + self.visible_rows) : (row += 1) {
            try tui.Screen.moveTo(writer, row, start_col);
            if (is_active) {
                try colors.border_active.apply(writer);
            } else {
                try colors.border_inactive.apply(writer);
            }
            try writer.writeAll("\xe2\x94\x82"); // │
            try theme_mod.Color.reset(writer);
            const content_width = if (self.width > 2) self.width - 2 else 0;
            var pad_count: u16 = content_width;
            while (pad_count > 0) : (pad_count -= 1) {
                try writer.writeAll(" ");
            }
            if (is_active) {
                try colors.border_active.apply(writer);
            } else {
                try colors.border_inactive.apply(writer);
            }
            try writer.writeAll("\xe2\x94\x82"); // │
            try theme_mod.Color.reset(writer);
        }

        // Draw bottom border.
        try tui.Screen.moveTo(writer, row, start_col);
        if (is_active) {
            try colors.border_active.apply(writer);
        } else {
            try colors.border_inactive.apply(writer);
        }
        try writer.writeAll("\xe2\x94\x94"); // └
        {
            var i: u16 = 0;
            const inner = if (self.width > 2) self.width - 2 else 0;
            while (i < inner) : (i += 1) {
                try writer.writeAll("\xe2\x94\x80"); // ─
            }
        }
        try writer.writeAll("\xe2\x94\x98"); // ┘
        try theme_mod.Color.reset(writer);
    }

    /// Handle a key event. Returns true if the key was consumed.
    pub fn handleKey(self: *List, key: tui.Key) bool {
        switch (key) {
            .arrow_up => {
                self.moveUp();
                return true;
            },
            .arrow_down => {
                self.moveDown();
                return true;
            },
            .page_up => {
                self.pageUp();
                return true;
            },
            .page_down => {
                self.pageDown();
                return true;
            },
            .home => {
                self.goToStart();
                return true;
            },
            .end => {
                self.goToEnd();
                return true;
            },
            else => return false,
        }
    }

    /// Calculate the total height this component needs (title + items + bottom border).
    pub fn totalHeight(self: *const List) u16 {
        return self.visible_rows + 2; // title bar + items + bottom border
    }
};

// --- Tests ---

test "List init with defaults" {
    const items = [_]List.ListItem{
        .{ .label = "test1", .description = "desc1", .category = "cat" },
        .{ .label = "test2", .description = "desc2", .category = "cat" },
    };
    const list = List.init(&items, "Test");
    try std.testing.expectEqual(@as(usize, 0), list.selected);
    try std.testing.expectEqual(@as(usize, 0), list.scroll_offset);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
}

test "List moveDown increments selection" {
    const items = [_]List.ListItem{
        .{ .label = "a", .description = "", .category = "" },
        .{ .label = "b", .description = "", .category = "" },
        .{ .label = "c", .description = "", .category = "" },
    };
    var list = List.init(&items, "");
    list.moveDown();
    try std.testing.expectEqual(@as(usize, 1), list.selected);
    list.moveDown();
    try std.testing.expectEqual(@as(usize, 2), list.selected);
}

test "List moveDown does not exceed bounds" {
    const items = [_]List.ListItem{
        .{ .label = "a", .description = "", .category = "" },
        .{ .label = "b", .description = "", .category = "" },
    };
    var list = List.init(&items, "");
    list.moveDown();
    list.moveDown();
    list.moveDown();
    try std.testing.expectEqual(@as(usize, 1), list.selected);
}

test "List moveUp decrements selection" {
    const items = [_]List.ListItem{
        .{ .label = "a", .description = "", .category = "" },
        .{ .label = "b", .description = "", .category = "" },
    };
    var list = List.init(&items, "");
    list.selected = 1;
    list.moveUp();
    try std.testing.expectEqual(@as(usize, 0), list.selected);
}

test "List moveUp does not go below zero" {
    const items = [_]List.ListItem{
        .{ .label = "a", .description = "", .category = "" },
    };
    var list = List.init(&items, "");
    list.moveUp();
    try std.testing.expectEqual(@as(usize, 0), list.selected);
}

test "List scroll adjusts on moveDown" {
    const items = [_]List.ListItem{
        .{ .label = "a", .description = "", .category = "" },
        .{ .label = "b", .description = "", .category = "" },
        .{ .label = "c", .description = "", .category = "" },
        .{ .label = "d", .description = "", .category = "" },
    };
    var list = List.init(&items, "");
    list.visible_rows = 2;
    list.moveDown(); // selected=1, visible
    try std.testing.expectEqual(@as(usize, 0), list.scroll_offset);
    list.moveDown(); // selected=2, needs scroll
    try std.testing.expectEqual(@as(usize, 1), list.scroll_offset);
    list.moveDown(); // selected=3
    try std.testing.expectEqual(@as(usize, 2), list.scroll_offset);
}

test "List scroll adjusts on moveUp" {
    const items = [_]List.ListItem{
        .{ .label = "a", .description = "", .category = "" },
        .{ .label = "b", .description = "", .category = "" },
        .{ .label = "c", .description = "", .category = "" },
    };
    var list = List.init(&items, "");
    list.visible_rows = 2;
    list.selected = 2;
    list.scroll_offset = 1;
    list.moveUp(); // selected=1, still visible
    try std.testing.expectEqual(@as(usize, 1), list.scroll_offset);
    list.moveUp(); // selected=0, needs scroll up
    try std.testing.expectEqual(@as(usize, 0), list.scroll_offset);
}

test "List goToStart and goToEnd" {
    const items = [_]List.ListItem{
        .{ .label = "a", .description = "", .category = "" },
        .{ .label = "b", .description = "", .category = "" },
        .{ .label = "c", .description = "", .category = "" },
    };
    var list = List.init(&items, "");
    list.visible_rows = 2;
    list.goToEnd();
    try std.testing.expectEqual(@as(usize, 2), list.selected);
    try std.testing.expectEqual(@as(usize, 1), list.scroll_offset);
    list.goToStart();
    try std.testing.expectEqual(@as(usize, 0), list.selected);
    try std.testing.expectEqual(@as(usize, 0), list.scroll_offset);
}

test "List getSelected returns correct item" {
    const items = [_]List.ListItem{
        .{ .label = "first", .description = "", .category = "" },
        .{ .label = "second", .description = "", .category = "" },
    };
    var list = List.init(&items, "");
    try std.testing.expectEqualStrings("first", list.getSelected().?.label);
    list.selected = 1;
    try std.testing.expectEqualStrings("second", list.getSelected().?.label);
}

test "List getSelected returns null for empty list" {
    const items = [_]List.ListItem{};
    const list = List.init(&items, "");
    try std.testing.expect(list.getSelected() == null);
}

test "List handleKey consumes arrow keys" {
    const items = [_]List.ListItem{
        .{ .label = "a", .description = "", .category = "" },
        .{ .label = "b", .description = "", .category = "" },
    };
    var list = List.init(&items, "");
    try std.testing.expect(list.handleKey(.arrow_down));
    try std.testing.expectEqual(@as(usize, 1), list.selected);
    try std.testing.expect(list.handleKey(.arrow_up));
    try std.testing.expectEqual(@as(usize, 0), list.selected);
}

test "List handleKey ignores unrelated keys" {
    const items = [_]List.ListItem{
        .{ .label = "a", .description = "", .category = "" },
    };
    var list = List.init(&items, "");
    try std.testing.expect(!list.handleKey(.enter));
    try std.testing.expect(!list.handleKey(.tab));
    try std.testing.expect(!list.handleKey(.{ .char = 'x' }));
}

test "List totalHeight calculation" {
    const items = [_]List.ListItem{};
    var list = List.init(&items, "");
    list.visible_rows = 10;
    try std.testing.expectEqual(@as(u16, 12), list.totalHeight());
}

test "List empty list operations do not crash" {
    const items = [_]List.ListItem{};
    var list = List.init(&items, "");
    list.moveUp();
    list.moveDown();
    list.pageUp();
    list.pageDown();
    list.goToStart();
    list.goToEnd();
    try std.testing.expectEqual(@as(usize, 0), list.selected);
}

test "List pageUp and pageDown" {
    var items_buf: [10]List.ListItem = undefined;
    for (&items_buf, 0..) |*item, i| {
        _ = i;
        item.* = .{ .label = "item", .description = "", .category = "" };
    }
    var list = List.init(&items_buf, "");
    list.visible_rows = 3;
    list.pageDown();
    try std.testing.expectEqual(@as(usize, 3), list.selected);
    list.pageDown();
    try std.testing.expectEqual(@as(usize, 6), list.selected);
    list.pageDown();
    try std.testing.expectEqual(@as(usize, 9), list.selected);
    list.pageDown(); // already at end
    try std.testing.expectEqual(@as(usize, 9), list.selected);
    list.pageUp();
    try std.testing.expectEqual(@as(usize, 6), list.selected);
    list.pageUp();
    try std.testing.expectEqual(@as(usize, 3), list.selected);
    list.pageUp();
    try std.testing.expectEqual(@as(usize, 0), list.selected);
}
