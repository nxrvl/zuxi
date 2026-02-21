const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

const available_licenses = "mit, apache2, gpl3, bsd2, bsd3, unlicense";

/// Entry point for the license command.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    const license_name = subcommand orelse {
        const writer = ctx.stderrWriter();
        try writer.print("license: license type required\n", .{});
        try writer.print("Usage: zuxi license <type> [author] [year]\n", .{});
        try writer.print("Available: {s}\n", .{available_licenses});
        return error.MissingArgument;
    };

    // Parse author and year from positional args.
    // Usage: zuxi license mit "Author Name" 2024
    // Or: zuxi license mit "Author Name" (year defaults to current)
    var author: []const u8 = "Your Name";
    var year_buf: [4]u8 = undefined;
    var year: []const u8 = undefined;

    // Default year from epoch.
    const epoch_seconds: u64 = @intCast(std.time.timestamp());
    const epoch_day = std.time.epoch.EpochDay{ .day = @intCast(@divTrunc(epoch_seconds, 86400)) };
    const year_day = epoch_day.calculateYearDay();
    const year_int = year_day.year;
    year = std.fmt.bufPrint(&year_buf, "{d}", .{year_int}) catch "2024";

    // Parse --author and --year flags from positional args, or plain positional args.
    var i: usize = 0;
    while (i < ctx.args.len) : (i += 1) {
        const arg = ctx.args[i];
        if (std.mem.eql(u8, arg, "--author") or std.mem.eql(u8, arg, "-a")) {
            i += 1;
            if (i < ctx.args.len) {
                author = ctx.args[i];
            }
        } else if (std.mem.eql(u8, arg, "--year") or std.mem.eql(u8, arg, "-y")) {
            i += 1;
            if (i < ctx.args.len) {
                year = ctx.args[i];
            }
        } else {
            // Positional: first = author, second = year.
            if (std.mem.eql(u8, author, "Your Name")) {
                author = arg;
            } else {
                year = arg;
            }
        }
    }

    const text = try generateLicenseAlloc(ctx.allocator, license_name, author, year) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("license: unknown license type '{s}'\n", .{license_name});
        try writer.print("Available: {s}\n", .{available_licenses});
        return error.InvalidArgument;
    };
    defer ctx.allocator.free(text);

    try io.writeOutput(ctx, text);
}

/// Generate the license text. Returns formatted text.
fn generateLicenseAlloc(allocator: std.mem.Allocator, name: []const u8, author: []const u8, year: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, name, "mit")) {
        return try std.fmt.allocPrint(allocator, mit_template, .{ year, author });
    }
    if (std.mem.eql(u8, name, "apache2")) {
        return try std.fmt.allocPrint(allocator, apache2_template, .{ year, author });
    }
    if (std.mem.eql(u8, name, "gpl3")) {
        return try std.fmt.allocPrint(allocator, gpl3_template, .{ year, author });
    }
    if (std.mem.eql(u8, name, "bsd2")) {
        return try std.fmt.allocPrint(allocator, bsd2_template, .{ year, author });
    }
    if (std.mem.eql(u8, name, "bsd3")) {
        return try std.fmt.allocPrint(allocator, bsd3_template, .{ year, author });
    }
    if (std.mem.eql(u8, name, "unlicense")) {
        return try allocator.dupe(u8, unlicense_template);
    }
    return null;
}

const mit_template =
    \\MIT License
    \\
    \\Copyright (c) {s} {s}
    \\
    \\Permission is hereby granted, free of charge, to any person obtaining a copy
    \\of this software and associated documentation files (the "Software"), to deal
    \\in the Software without restriction, including without limitation the rights
    \\to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    \\copies of the Software, and to permit persons to whom the Software is
    \\furnished to do so, subject to the following conditions:
    \\
    \\The above copyright notice and this permission notice shall be included in all
    \\copies or substantial portions of the Software.
    \\
    \\THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    \\IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    \\FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    \\AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    \\LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    \\OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    \\SOFTWARE.
    \\
;

const apache2_template =
    \\                                 Apache License
    \\                           Version 2.0, January 2004
    \\                        http://www.apache.org/licenses/
    \\
    \\   Copyright {s} {s}
    \\
    \\   Licensed under the Apache License, Version 2.0 (the "License");
    \\   you may not use this file except in compliance with the License.
    \\   You may obtain a copy of the License at
    \\
    \\       http://www.apache.org/licenses/LICENSE-2.0
    \\
    \\   Unless required by applicable law or agreed to in writing, software
    \\   distributed under the License is distributed on an "AS IS" BASIS,
    \\   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    \\   See the License for the specific language governing permissions and
    \\   limitations under the License.
    \\
;

const gpl3_template =
    \\                    GNU GENERAL PUBLIC LICENSE
    \\                       Version 3, 29 June 2007
    \\
    \\   Copyright (C) {s} {s}
    \\
    \\   This program is free software: you can redistribute it and/or modify
    \\   it under the terms of the GNU General Public License as published by
    \\   the Free Software Foundation, either version 3 of the License, or
    \\   (at your option) any later version.
    \\
    \\   This program is distributed in the hope that it will be useful,
    \\   but WITHOUT ANY WARRANTY; without even the implied warranty of
    \\   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    \\   GNU General Public License for more details.
    \\
    \\   You should have received a copy of the GNU General Public License
    \\   along with this program.  If not, see <https://www.gnu.org/licenses/>.
    \\
;

const bsd2_template =
    \\BSD 2-Clause License
    \\
    \\Copyright (c) {s}, {s}
    \\All rights reserved.
    \\
    \\Redistribution and use in source and binary forms, with or without
    \\modification, are permitted provided that the following conditions are met:
    \\
    \\1. Redistributions of source code must retain the above copyright notice, this
    \\   list of conditions and the following disclaimer.
    \\
    \\2. Redistributions in binary form must reproduce the above copyright notice,
    \\   this list of conditions and the following disclaimer in the documentation
    \\   and/or other materials provided with the distribution.
    \\
    \\THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
    \\AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
    \\IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    \\DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
    \\FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
    \\DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
    \\SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    \\CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
    \\OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
    \\OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
    \\
;

const bsd3_template =
    \\BSD 3-Clause License
    \\
    \\Copyright (c) {s}, {s}
    \\All rights reserved.
    \\
    \\Redistribution and use in source and binary forms, with or without
    \\modification, are permitted provided that the following conditions are met:
    \\
    \\1. Redistributions of source code must retain the above copyright notice, this
    \\   list of conditions and the following disclaimer.
    \\
    \\2. Redistributions in binary form must reproduce the above copyright notice,
    \\   this list of conditions and the following disclaimer in the documentation
    \\   and/or other materials provided with the distribution.
    \\
    \\3. Neither the name of the copyright holder nor the names of its
    \\   contributors may be used to endorse or promote products derived from
    \\   this software without specific prior written permission.
    \\
    \\THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
    \\AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
    \\IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    \\DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
    \\FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
    \\DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
    \\SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    \\CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
    \\OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
    \\OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
    \\
;

const unlicense_template =
    \\This is free and unencumbered software released into the public domain.
    \\
    \\Anyone is free to copy, modify, publish, use, compile, sell, or
    \\distribute this software, either in source code form or as a compiled
    \\binary, for any purpose, commercial or non-commercial, and by any
    \\means.
    \\
    \\In jurisdictions that recognize copyright laws, the author or authors
    \\of this software dedicate any and all copyright interest in the
    \\software to the public domain. We make this dedication for the benefit
    \\of the public at large and to the detriment of our heirs and
    \\successors. We intend this dedication to be an overt act of
    \\relinquishment in perpetuity of all present and future rights to this
    \\software under copyright law.
    \\
    \\THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
    \\EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
    \\MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
    \\IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
    \\OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
    \\ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
    \\OTHER DEALINGS IN THE SOFTWARE.
    \\
    \\For more information, please refer to <https://unlicense.org>
    \\
;

/// Command definition for registration.
pub const command = registry.Command{
    .name = "license",
    .description = "Generate license text",
    .category = .dev,
    .subcommands = &.{ "mit", "apache2", "gpl3", "bsd2", "bsd3", "unlicense" },
    .execute = execute,
};

// --- Tests ---

fn execLicense(subcommand: ?[]const u8, args: []const []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_license_out.tmp";

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

test "license mit" {
    const empty_args = [_][]const u8{ "TestAuthor", "2024" };
    const output = try execLicense("mit", &empty_args);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "MIT License") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "TestAuthor") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2024") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Permission is hereby granted") != null);
}

test "license apache2" {
    const args = [_][]const u8{"TestCorp"};
    const output = try execLicense("apache2", &args);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Apache License") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "TestCorp") != null);
}

test "license gpl3" {
    const args = [_][]const u8{"TestDev"};
    const output = try execLicense("gpl3", &args);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "GNU GENERAL PUBLIC LICENSE") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "TestDev") != null);
}

test "license bsd2" {
    const args = [_][]const u8{"BSD Author"};
    const output = try execLicense("bsd2", &args);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "BSD 2-Clause License") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "BSD Author") != null);
}

test "license bsd3" {
    const args = [_][]const u8{"BSD3 Author"};
    const output = try execLicense("bsd3", &args);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "BSD 3-Clause License") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "BSD3 Author") != null);
}

test "license unlicense" {
    const empty = [_][]const u8{};
    const output = try execLicense("unlicense", &empty);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "public domain") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "unlicense.org") != null);
}

test "license with --author and --year flags" {
    const args = [_][]const u8{ "--author", "FlagAuthor", "--year", "2025" };
    const output = try execLicense("mit", &args);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "FlagAuthor") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2025") != null);
}

test "license no subcommand returns error" {
    const empty = [_][]const u8{};
    const result = execLicense(null, &empty);
    try std.testing.expectError(error.MissingArgument, result);
}

test "license unknown type returns error" {
    const empty = [_][]const u8{};
    const result = execLicense("wtfpl", &empty);
    try std.testing.expectError(error.InvalidArgument, result);
}

test "license command struct fields" {
    try std.testing.expectEqualStrings("license", command.name);
    try std.testing.expectEqual(registry.Category.dev, command.category);
    try std.testing.expectEqual(@as(usize, 6), command.subcommands.len);
}
