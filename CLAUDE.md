# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Zuxi** is a cross-platform offline developer toolkit written in **Zig** — a modular CLI/TUI Swiss-army knife compiled into a single static binary. No telemetry, no external runtime dependencies.

The project spec is in `docs/description.md` (written in Russian).

## Build & Development

```bash
zig build              # Build the project
zig build run          # Build and run
zig build test         # Run all tests
zig test src/file.zig  # Run tests in a single file
```

## GIT

Never add co-author, alwayes use only main useg account during commit

## Architecture

Zuxi has two modes sharing the same command engine:
- **CLI mode**: `zuxi <command> [subcommand] [flags]` — pipe-friendly, stdin/stdout
- **TUI mode**: `zuxi` (no args) — interactive terminal UI with live preview

### Project Structure

```
src/
  main.zig              # Entry point, mode dispatch
  core/
    registry.zig         # Command registration system
    context.zig          # Execution context passed to commands
    cli.zig              # CLI argument parsing and dispatch
    tui.zig              # TUI rendering and interaction
    io.zig               # Stdin/stdout/file I/O helpers
    errors.zig           # Unified error types
  commands/              # Each command is an independent module
    json/                # jsonfmt, jsonpath, jsonrepair, etc.
    encoding/            # base64, urlencode, strcase, etc.
    security/            # jwt, hash, hmac, certinspect, etc.
    time/                # time conversion, cron, durationcalc
    dev/                 # uuid, http, ports, envfile, etc.
  ui/
    components/          # TUI widgets
    layout/              # TUI layout system
    themes/              # Dark/light themes
```

### Key Design Principles

- Every command is a self-contained module registered via `core/registry.zig`
- CLI and TUI share identical command logic — UI is a separate layer
- Commands receive a `Context` struct with I/O handles, flags, and config
- Support "lite" and "full" build configurations via build options

### Global CLI Flags

All commands support: `--help`, `--version`, `--output <file>`, `--format json|text`, `--no-color`, `--quiet`

### Adding a New Command

1. Create a module under the appropriate `commands/` subdirectory
2. Implement the command interface expected by the registry
3. Register the command in `core/registry.zig`
4. The command automatically becomes available in both CLI and TUI modes

## MVP Commands (v0.1)

jsonfmt, base64, strcase, hash (sha256/sha512/md5), time (unix/rfc3339), jwt (decode), http (GET/POST), uuid (generate/decode)

## Constraints

- Static binary, cross-compiled
- Binary size target: < 10–15 MB
- Startup time: < 50ms
- No network dependencies except the `http` command
- Language: Zig (idiomatic style, prefer comptime where beneficial)
