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
    color.zig            # ANSI color output and JSON syntax highlighting
  formats/               # Format parsers/serializers (used by conversion commands)
    yaml.zig             # YAML parser and serializer
    toml.zig             # TOML parser and serializer
    xml.zig              # XML parser and serializer
  commands/              # Each command is an independent module
    json/                # jsonfmt, jsonpath, jsonrepair, jsonstruct, yamlfmt, yamlstruct, tomlfmt, xmlfmt, format conversions
    encoding/            # base64, urlencode, strcase, count, slug
    security/            # jwt, hash, hmac
    time/                # time conversion, cron
    dev/                 # uuid, http, ports, envfile, serve, scaffold, gitignore, license, iban, numbers, urls
    docs/                # csv2json, csv2md, tsv2md, cssfmt, cssmin, htmlfmt, gqlquery
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

## Implemented Commands

**MVP (v0.1):** jsonfmt, base64, strcase, hash, time, jwt, http, uuid

**v0.2 additions:**
- Text: count, slug, urlencode
- JSON toolkit: jsonrepair, jsonpath, jsonstruct
- Format tools: yamlfmt, yamlstruct, tomlfmt, xmlfmt
- Conversions: json2yaml, yaml2json, json2toml, toml2json, json2xml, xml2json, yaml2toml, toml2yaml
- CSV/TSV: csv2json, csv2md, tsv2md
- Web formats: cssfmt, cssmin, htmlfmt, gqlquery
- Security: hmac
- Dev: numbers, urls, ports, envfile, serve, scaffold, gitignore, license, iban
- Time: cron
- Color output: ANSI syntax highlighting for JSON, JWT, HTTP responses (respects --no-color and pipe detection)

## Constraints

- Static binary, cross-compiled
- Binary size target: < 10–15 MB
- Startup time: < 50ms
- No network dependencies except the `http` command
- Language: Zig (idiomatic style, prefer comptime where beneficial)
