const std = @import("std");
const tui = @import("../../core/tui.zig");
const theme_mod = @import("../themes/theme.zig");

/// Layout region describing a rectangular area on screen.
pub const Region = struct {
    /// Top-left row (1-based for terminal).
    row: u16,
    /// Top-left column (1-based).
    col: u16,
    /// Width in columns.
    width: u16,
    /// Height in rows.
    height: u16,
};

/// Panel identifiers for the split layout.
pub const Panel = enum {
    left,
    right_top,
    right_bottom,
};

/// A split layout with a left panel and a right panel split into top/bottom.
/// Left panel: category/command list.
/// Right top: text input area.
/// Right bottom: preview/output area.
pub const SplitLayout = struct {
    /// Total available width.
    total_width: u16,
    /// Total available height (excluding status bar).
    total_height: u16,
    /// Left panel width as a fraction (0.0 to 1.0).
    left_ratio: f32,
    /// Right top/bottom split ratio (fraction of right area for top).
    top_ratio: f32,
    /// Top row offset (1-based, for status bar etc.).
    top_offset: u16,

    /// Create a default split layout.
    pub fn init(width: u16, height: u16) SplitLayout {
        return .{
            .total_width = width,
            .total_height = height,
            .left_ratio = 0.25,
            .top_ratio = 0.5,
            .top_offset = 2, // leave row 1 for status bar
        };
    }

    /// Calculate the region for the left panel.
    pub fn leftRegion(self: SplitLayout) Region {
        const left_width = self.leftWidth();
        const usable_height = self.usableHeight();
        return .{
            .row = self.top_offset,
            .col = 1,
            .width = left_width,
            .height = usable_height,
        };
    }

    /// Calculate the region for the right-top panel.
    pub fn rightTopRegion(self: SplitLayout) Region {
        const left_w = self.leftWidth();
        const right_w = self.rightWidth();
        const usable_h = self.usableHeight();
        const top_h = self.rightTopHeight(usable_h);
        return .{
            .row = self.top_offset,
            .col = left_w + 1,
            .width = right_w,
            .height = top_h,
        };
    }

    /// Calculate the region for the right-bottom panel.
    pub fn rightBottomRegion(self: SplitLayout) Region {
        const left_w = self.leftWidth();
        const right_w = self.rightWidth();
        const usable_h = self.usableHeight();
        const top_h = self.rightTopHeight(usable_h);
        const bottom_h = usable_h - top_h;
        return .{
            .row = self.top_offset + top_h,
            .col = left_w + 1,
            .width = right_w,
            .height = bottom_h,
        };
    }

    /// Calculate the region for the status bar (bottom row).
    pub fn statusBarRegion(self: SplitLayout) Region {
        return .{
            .row = 1,
            .col = 1,
            .width = self.total_width,
            .height = 1,
        };
    }

    fn leftWidth(self: SplitLayout) u16 {
        const w = @as(u16, @intFromFloat(@as(f32, @floatFromInt(self.total_width)) * self.left_ratio));
        return @max(w, 10); // minimum 10 columns for left panel
    }

    fn rightWidth(self: SplitLayout) u16 {
        const lw = self.leftWidth();
        if (self.total_width <= lw) return 1;
        return self.total_width - lw;
    }

    fn usableHeight(self: SplitLayout) u16 {
        if (self.total_height > self.top_offset) {
            return self.total_height - self.top_offset + 1;
        }
        return 1;
    }

    fn rightTopHeight(self: SplitLayout, usable: u16) u16 {
        const h = @as(u16, @intFromFloat(@as(f32, @floatFromInt(usable)) * self.top_ratio));
        const clamped = @max(h, 3); // minimum 3 rows
        // Don't exceed usable height; leave at least 1 row for bottom panel.
        if (usable <= 1) return usable;
        return @min(clamped, usable - 1);
    }

    /// Update layout dimensions (e.g., on terminal resize).
    pub fn resize(self: *SplitLayout, width: u16, height: u16) void {
        self.total_width = width;
        self.total_height = height;
    }

    /// Render the status bar.
    pub fn renderStatusBar(self: SplitLayout, writer: anytype, colors: theme_mod.ColorScheme, status_text: []const u8) !void {
        const region = self.statusBarRegion();
        try tui.Screen.moveTo(writer, region.row, region.col);
        try colors.status_bar.apply(writer);
        const text_len = @min(status_text.len, region.width);
        try writer.writeAll(status_text[0..text_len]);
        // Pad the rest of the status bar.
        var remaining: u16 = region.width - @as(u16, @intCast(text_len));
        while (remaining > 0) : (remaining -= 1) {
            try writer.writeAll(" ");
        }
        try theme_mod.Color.reset(writer);
    }
};

// --- Tests ---

test "SplitLayout init with default ratios" {
    const layout = SplitLayout.init(80, 24);
    try std.testing.expectEqual(@as(u16, 80), layout.total_width);
    try std.testing.expectEqual(@as(u16, 24), layout.total_height);
    try std.testing.expect(layout.left_ratio > 0.0 and layout.left_ratio < 1.0);
    try std.testing.expect(layout.top_ratio > 0.0 and layout.top_ratio < 1.0);
}

test "SplitLayout leftRegion calculation" {
    const layout = SplitLayout.init(80, 24);
    const region = layout.leftRegion();
    try std.testing.expectEqual(@as(u16, 2), region.row);
    try std.testing.expectEqual(@as(u16, 1), region.col);
    try std.testing.expect(region.width > 0);
    try std.testing.expect(region.height > 0);
    try std.testing.expect(region.width < 80);
}

test "SplitLayout regions do not overlap horizontally" {
    const layout = SplitLayout.init(100, 30);
    const left = layout.leftRegion();
    const rt = layout.rightTopRegion();
    const rb = layout.rightBottomRegion();

    // Right panels start after left panel.
    try std.testing.expect(rt.col > left.col);
    try std.testing.expect(rb.col > left.col);
    // Right top and bottom have the same column.
    try std.testing.expectEqual(rt.col, rb.col);
    // Left width + right width = total width.
    try std.testing.expectEqual(@as(u16, 100), left.width + rt.width);
}

test "SplitLayout right panels do not overlap vertically" {
    const layout = SplitLayout.init(80, 30);
    const rt = layout.rightTopRegion();
    const rb = layout.rightBottomRegion();

    // Bottom starts after top ends.
    try std.testing.expect(rb.row >= rt.row + rt.height);
    // Combined height equals usable height.
    try std.testing.expectEqual(rt.height + rb.height, layout.total_height - layout.top_offset + 1);
}

test "SplitLayout statusBarRegion" {
    const layout = SplitLayout.init(80, 24);
    const sb = layout.statusBarRegion();
    try std.testing.expectEqual(@as(u16, 1), sb.row);
    try std.testing.expectEqual(@as(u16, 1), sb.col);
    try std.testing.expectEqual(@as(u16, 80), sb.width);
    try std.testing.expectEqual(@as(u16, 1), sb.height);
}

test "SplitLayout resize updates dimensions" {
    var layout = SplitLayout.init(80, 24);
    layout.resize(120, 40);
    try std.testing.expectEqual(@as(u16, 120), layout.total_width);
    try std.testing.expectEqual(@as(u16, 40), layout.total_height);
}

test "SplitLayout minimum widths are respected" {
    // Even with a tiny terminal, left panel should be at least 10.
    const layout = SplitLayout.init(20, 10);
    const left = layout.leftRegion();
    try std.testing.expect(left.width >= 10);
}

test "SplitLayout minimum heights are respected" {
    const layout = SplitLayout.init(80, 10);
    const rt = layout.rightTopRegion();
    try std.testing.expect(rt.height >= 3);
}

test "Region has valid dimensions" {
    const region = Region{ .row = 1, .col = 1, .width = 40, .height = 20 };
    try std.testing.expect(region.width > 0);
    try std.testing.expect(region.height > 0);
}

test "SplitLayout large terminal" {
    const layout = SplitLayout.init(200, 60);
    const left = layout.leftRegion();
    const rt = layout.rightTopRegion();
    const rb = layout.rightBottomRegion();

    // Sanity checks.
    try std.testing.expect(left.width + rt.width == 200);
    try std.testing.expect(rt.height + rb.height > 0);
    try std.testing.expectEqual(@as(u16, 200), left.width + rb.width);
}
