const std = @import("std");

/// A parsed CSV/TSV table: rows of fields.
pub const Table = struct {
    rows: []const []const []const u8,
    allocator: std.mem.Allocator,
    /// Internal storage for all allocated field strings.
    _field_buf: [][]const u8,
    /// Internal storage for row slices.
    _row_buf: [][]const []const u8,

    pub fn deinit(self: Table) void {
        for (self._field_buf) |f| {
            self.allocator.free(f);
        }
        self.allocator.free(self._field_buf);
        self.allocator.free(self._row_buf);
    }
};

/// Parse CSV (or TSV) data into a Table.
/// Handles RFC 4180: quoted fields, escaped quotes (""), delimiters in quoted fields.
pub fn parse(allocator: std.mem.Allocator, data: []const u8, delimiter: u8) !Table {
    var fields = std.ArrayList([]const u8){};
    defer fields.deinit(allocator);
    var row_field_counts = std.ArrayList(usize){};
    defer row_field_counts.deinit(allocator);

    var i: usize = 0;
    var field_count_in_row: usize = 0;

    while (true) {
        // Parse one field
        if (i < data.len and data[i] == '"') {
            const field = try parseQuotedField(allocator, data, &i);
            try fields.append(allocator, field);
        } else {
            const start = i;
            while (i < data.len and data[i] != delimiter and data[i] != '\n' and data[i] != '\r') {
                i += 1;
            }
            const field = try allocator.dupe(u8, data[start..i]);
            try fields.append(allocator, field);
        }
        field_count_in_row += 1;

        // After field: delimiter, newline, or EOF
        if (i >= data.len) {
            // EOF - finalize row
            try row_field_counts.append(allocator, field_count_in_row);
            break;
        } else if (data[i] == delimiter) {
            i += 1;
            // Continue to next field in same row
        } else if (data[i] == '\n' or data[i] == '\r') {
            // End of row
            try row_field_counts.append(allocator, field_count_in_row);
            field_count_in_row = 0;
            skipNewline(data, &i);
            if (i >= data.len) break; // trailing newline, no more rows
        }
    }

    // Build row slices from flat field array
    const field_buf = try fields.toOwnedSlice(allocator);
    const num_rows = row_field_counts.items.len;
    const row_buf = try allocator.alloc([]const []const u8, num_rows);

    var offset: usize = 0;
    for (row_field_counts.items, 0..) |count, ri| {
        row_buf[ri] = field_buf[offset .. offset + count];
        offset += count;
    }

    return Table{
        .rows = row_buf,
        .allocator = allocator,
        ._field_buf = field_buf,
        ._row_buf = row_buf,
    };
}

/// Parse a quoted field starting at data[*pos] which should be '"'.
/// Advances pos past the closing quote.
fn parseQuotedField(allocator: std.mem.Allocator, data: []const u8, pos: *usize) ![]u8 {
    std.debug.assert(data[pos.*] == '"');
    pos.* += 1; // skip opening quote

    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    while (pos.* < data.len) {
        if (data[pos.*] == '"') {
            pos.* += 1;
            if (pos.* < data.len and data[pos.*] == '"') {
                // Escaped quote ""
                try result.append(allocator, '"');
                pos.* += 1;
            } else {
                // End of quoted field
                break;
            }
        } else {
            try result.append(allocator, data[pos.*]);
            pos.* += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Skip \r\n or \n.
fn skipNewline(data: []const u8, pos: *usize) void {
    if (pos.* < data.len and data[pos.*] == '\r') {
        pos.* += 1;
    }
    if (pos.* < data.len and data[pos.*] == '\n') {
        pos.* += 1;
    }
}

// --- Tests ---

test "parse simple CSV" {
    const data = "a,b,c\n1,2,3\n";
    const table = try parse(std.testing.allocator, data, ',');
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 2), table.rows.len);
    try std.testing.expectEqual(@as(usize, 3), table.rows[0].len);
    try std.testing.expectEqualStrings("a", table.rows[0][0]);
    try std.testing.expectEqualStrings("b", table.rows[0][1]);
    try std.testing.expectEqualStrings("c", table.rows[0][2]);
    try std.testing.expectEqualStrings("1", table.rows[1][0]);
    try std.testing.expectEqualStrings("2", table.rows[1][1]);
    try std.testing.expectEqualStrings("3", table.rows[1][2]);
}

test "parse CSV without trailing newline" {
    const data = "x,y\n1,2";
    const table = try parse(std.testing.allocator, data, ',');
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 2), table.rows.len);
    try std.testing.expectEqualStrings("x", table.rows[0][0]);
    try std.testing.expectEqualStrings("y", table.rows[0][1]);
    try std.testing.expectEqualStrings("1", table.rows[1][0]);
    try std.testing.expectEqualStrings("2", table.rows[1][1]);
}

test "parse CSV with quoted fields containing comma" {
    const data = "name,desc\n\"Alice\",\"Hello, World\"\n";
    const table = try parse(std.testing.allocator, data, ',');
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 2), table.rows.len);
    try std.testing.expectEqualStrings("Alice", table.rows[1][0]);
    try std.testing.expectEqualStrings("Hello, World", table.rows[1][1]);
}

test "parse CSV with escaped quotes" {
    const data = "a\n\"He said \"\"hi\"\"\"\n";
    const table = try parse(std.testing.allocator, data, ',');
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 2), table.rows.len);
    try std.testing.expectEqualStrings("He said \"hi\"", table.rows[1][0]);
}

test "parse TSV simple" {
    const data = "a\tb\tc\n1\t2\t3\n";
    const table = try parse(std.testing.allocator, data, '\t');
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 2), table.rows.len);
    try std.testing.expectEqualStrings("a", table.rows[0][0]);
    try std.testing.expectEqualStrings("b", table.rows[0][1]);
    try std.testing.expectEqualStrings("c", table.rows[0][2]);
    try std.testing.expectEqualStrings("1", table.rows[1][0]);
    try std.testing.expectEqualStrings("2", table.rows[1][1]);
    try std.testing.expectEqualStrings("3", table.rows[1][2]);
}

test "parse CSV with CRLF" {
    const data = "a,b\r\n1,2\r\n";
    const table = try parse(std.testing.allocator, data, ',');
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 2), table.rows.len);
    try std.testing.expectEqualStrings("a", table.rows[0][0]);
    try std.testing.expectEqualStrings("b", table.rows[0][1]);
    try std.testing.expectEqualStrings("1", table.rows[1][0]);
    try std.testing.expectEqualStrings("2", table.rows[1][1]);
}

test "parse empty fields" {
    const data = "a,,c\n,2,\n";
    const table = try parse(std.testing.allocator, data, ',');
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 2), table.rows.len);
    try std.testing.expectEqual(@as(usize, 3), table.rows[0].len);
    try std.testing.expectEqualStrings("a", table.rows[0][0]);
    try std.testing.expectEqualStrings("", table.rows[0][1]);
    try std.testing.expectEqualStrings("c", table.rows[0][2]);
    try std.testing.expectEqualStrings("", table.rows[1][0]);
    try std.testing.expectEqualStrings("2", table.rows[1][1]);
    try std.testing.expectEqualStrings("", table.rows[1][2]);
}

test "parse single field" {
    const data = "hello";
    const table = try parse(std.testing.allocator, data, ',');
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 1), table.rows.len);
    try std.testing.expectEqualStrings("hello", table.rows[0][0]);
}

test "parse quoted field with newline inside" {
    const data = "a,b\n\"line1\nline2\",val\n";
    const table = try parse(std.testing.allocator, data, ',');
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 2), table.rows.len);
    try std.testing.expectEqualStrings("line1\nline2", table.rows[1][0]);
    try std.testing.expectEqualStrings("val", table.rows[1][1]);
}
