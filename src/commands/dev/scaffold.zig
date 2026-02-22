const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// .env template content.
const env_template =
    \\# Application
    \\APP_NAME=myapp
    \\APP_ENV=development
    \\APP_PORT=3000
    \\APP_DEBUG=true
    \\
    \\# Database
    \\DB_HOST=localhost
    \\DB_PORT=5432
    \\DB_NAME=myapp_dev
    \\DB_USER=postgres
    \\DB_PASSWORD=
    \\
    \\# Redis
    \\REDIS_HOST=localhost
    \\REDIS_PORT=6379
    \\
    \\# Auth
    \\JWT_SECRET=change-me-in-production
    \\JWT_EXPIRY=3600
    \\
    \\# Logging
    \\LOG_LEVEL=debug
    \\
;

/// docker-compose.yml template content.
const compose_template =
    \\version: "3.8"
    \\
    \\services:
    \\  app:
    \\    build: .
    \\    ports:
    \\      - "${APP_PORT:-3000}:3000"
    \\    environment:
    \\      - APP_ENV=${APP_ENV:-development}
    \\      - DB_HOST=db
    \\      - DB_PORT=5432
    \\      - REDIS_HOST=redis
    \\    depends_on:
    \\      - db
    \\      - redis
    \\    volumes:
    \\      - .:/app
    \\    restart: unless-stopped
    \\
    \\  db:
    \\    image: postgres:16-alpine
    \\    environment:
    \\      POSTGRES_DB: ${DB_NAME:-myapp_dev}
    \\      POSTGRES_USER: ${DB_USER:-postgres}
    \\      POSTGRES_PASSWORD: ${DB_PASSWORD:-postgres}
    \\    ports:
    \\      - "${DB_PORT:-5432}:5432"
    \\    volumes:
    \\      - pgdata:/var/lib/postgresql/data
    \\    restart: unless-stopped
    \\
    \\  redis:
    \\    image: redis:7-alpine
    \\    ports:
    \\      - "${REDIS_PORT:-6379}:6379"
    \\    restart: unless-stopped
    \\
    \\volumes:
    \\  pgdata:
    \\
;

/// Entry point for the scaffold command.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    const template: enum { env, compose } = if (subcommand) |sub| blk: {
        if (std.mem.eql(u8, sub, "env")) break :blk .env;
        if (std.mem.eql(u8, sub, "compose")) break :blk .compose;
        const writer = ctx.stderrWriter();
        try writer.print("scaffold: unknown subcommand '{s}'\n", .{sub});
        try writer.print("Available subcommands: env, compose\n", .{});
        return error.InvalidArgument;
    } else {
        const writer = ctx.stderrWriter();
        try writer.print("scaffold: subcommand required\n", .{});
        try writer.print("Available subcommands: env, compose\n", .{});
        return error.MissingArgument;
    };

    switch (template) {
        .env => try io.writeOutput(ctx, env_template),
        .compose => try io.writeOutput(ctx, compose_template),
    }
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "scaffold",
    .description = "Generate project file templates",
    .category = .dev,
    .subcommands = &.{ "env", "compose" },
    .execute = execute,
};

// --- Tests ---

fn execWithInput(subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_scaffold_out.tmp";

    const out_file = try std.fs.cwd().createFile(tmp_out, .{});

    var ctx = context.Context.initDefault(allocator);
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

test "scaffold env generates .env template" {
    const output = try execWithInput("env");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "APP_NAME=myapp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "DB_HOST=localhost") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "JWT_SECRET=") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "LOG_LEVEL=debug") != null);
}

test "scaffold env has comment sections" {
    const output = try execWithInput("env");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "# Application") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "# Database") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "# Redis") != null);
}

test "scaffold compose generates docker-compose template" {
    const output = try execWithInput("compose");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "version:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "services:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "postgres:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "redis:") != null);
}

test "scaffold compose has app service" {
    const output = try execWithInput("compose");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "app:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "depends_on:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "volumes:") != null);
}

test "scaffold compose has db service" {
    const output = try execWithInput("compose");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "db:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "POSTGRES_DB:") != null);
}

test "scaffold no subcommand returns error" {
    const result = execWithInput(null);
    try std.testing.expectError(error.MissingArgument, result);
}

test "scaffold unknown subcommand returns error" {
    const result = execWithInput("unknown");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "scaffold command struct fields" {
    try std.testing.expectEqualStrings("scaffold", command.name);
    try std.testing.expectEqual(registry.Category.dev, command.category);
    try std.testing.expectEqual(@as(usize, 2), command.subcommands.len);
}
