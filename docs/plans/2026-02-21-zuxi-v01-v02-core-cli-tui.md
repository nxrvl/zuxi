# Zuxi v0.1 + v0.2: Core + CLI MVP + TUI

## Overview

Build Zuxi from scratch: project scaffolding, core framework (registry, context, CLI parser, I/O), all 8 MVP commands (jsonfmt, base64, strcase, hash, time, jwt, http, uuid), and the TUI interactive interface. The result is a single static Zig binary with both CLI and TUI modes.

## Context

- Files involved: entire src/ tree (to be created), build.zig
- Related patterns: none (greenfield project)
- Dependencies: Zig standard library only (no external packages)

## Development Approach

- **Testing approach**: Regular (code first, then tests)
- Complete each task fully before moving to the next
- First command (jsonfmt) establishes the pattern all other commands follow
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Project scaffolding and build system

**Files:**
- Create: `build.zig`
- Create: `src/main.zig`

- [x] Create build.zig with executable target "zuxi", test step, and run step
- [x] Add build options for "lite" vs "full" build configuration
- [x] Create src/main.zig with basic entry point that prints version and exits
- [x] Verify `zig build`, `zig build run`, and `zig build test` all work
- [x] Write a basic smoke test in main.zig

### Task 2: Core framework - errors, context, I/O

**Files:**
- Create: `src/core/errors.zig`
- Create: `src/core/context.zig`
- Create: `src/core/io.zig`

- [x] Implement errors.zig: unified error set (InvalidInput, IoError, FormatError, etc.)
- [x] Implement context.zig: Context struct with stdin/stdout/stderr handles, flags (format, no-color, quiet, output file), and config
- [x] Implement io.zig: helpers for reading stdin (all or line-by-line), writing to stdout or output file, detecting if stdin is a pipe
- [x] Write tests for each module
- [x] Run test suite - must pass before task 3

### Task 3: Command registry and CLI argument parser

**Files:**
- Create: `src/core/registry.zig`
- Create: `src/core/cli.zig`
- Modify: `src/main.zig`

- [x] Implement registry.zig: Command interface (name, description, category, execute fn), Registry struct with register/lookup/list methods
- [x] Implement cli.zig: argument parser supporting `zuxi <command> [subcommand] [flags]`, parse global flags (--help, --version, --output, --format, --no-color, --quiet)
- [x] Wire up main.zig: parse args -> if no args prepare for TUI (stub for now) -> otherwise dispatch to CLI
- [x] Implement --help (list all commands) and --version output
- [x] Write tests for registry and CLI parser
- [x] Run test suite - must pass before task 4

### Task 4: jsonfmt command

**Files:**
- Create: `src/commands/json/jsonfmt.zig`

- [x] Implement prettify (indent JSON), minify (compact JSON), and validate modes
- [x] Support subcommands: `zuxi jsonfmt` (default prettify), `zuxi jsonfmt minify`, `zuxi jsonfmt validate`
- [x] Read input from stdin or argument, write to stdout or --output file
- [x] Register in the command registry
- [x] Write tests: valid JSON prettify/minify, invalid JSON error, stdin pipe input
- [x] Run test suite - must pass before task 5

### Task 5: Encoding commands - base64, strcase

**Files:**
- Create: `src/commands/encoding/base64.zig`
- Create: `src/commands/encoding/strcase.zig`

- [ ] Implement base64 encode/decode subcommands using Zig std lib
- [ ] Implement strcase with subcommands: snake, camel, pascal, kebab, upper
- [ ] Register both commands in the registry
- [ ] Write tests for base64 (encode, decode, invalid input) and strcase (all case conversions)
- [ ] Run test suite - must pass before task 6

### Task 6: Security commands - hash, jwt

**Files:**
- Create: `src/commands/security/hash.zig`
- Create: `src/commands/security/jwt.zig`

- [ ] Implement hash with subcommands: sha256, sha512, md5 - support string input and file input
- [ ] Implement jwt decode: split JWT, base64-decode header and payload, display as formatted JSON, show exp/iat timestamps as human-readable, indicate if expired
- [ ] Register both commands in the registry
- [ ] Write tests for hash (known hash values) and jwt (decode known tokens, invalid tokens)
- [ ] Run test suite - must pass before task 7

### Task 7: Utility commands - time, uuid

**Files:**
- Create: `src/commands/time/time.zig`
- Create: `src/commands/dev/uuid.zig`

- [ ] Implement time: unix-to-rfc3339, rfc3339-to-unix, show current time in UTC and local
- [ ] Implement uuid: generate (v4 random), decode (extract version, variant, timestamp if v1)
- [ ] Register both commands in the registry
- [ ] Write tests for time (known conversions) and uuid (format validation, generation uniqueness)
- [ ] Run test suite - must pass before task 8

### Task 8: http command

**Files:**
- Create: `src/commands/security/http.zig`

- [ ] Implement HTTP client using Zig std.http.Client: GET and POST methods
- [ ] Support flags: --header (repeatable), --body (for POST), --json (set content-type and parse response)
- [ ] Pretty-print JSON responses when detected, show status code and headers
- [ ] Register command in the registry
- [ ] Write tests for request building and response parsing (mock or known endpoints)
- [ ] Run test suite - must pass before task 9

### Task 9: TUI framework - rendering and layout

**Files:**
- Create: `src/core/tui.zig`
- Create: `src/ui/components/list.zig`
- Create: `src/ui/components/textinput.zig`
- Create: `src/ui/components/preview.zig`
- Create: `src/ui/layout/split.zig`
- Create: `src/ui/themes/theme.zig`

- [ ] Implement tui.zig: terminal raw mode, screen clearing, cursor movement, key input reading using Zig std lib
- [ ] Implement list component: scrollable list with highlight for category/command navigation
- [ ] Implement text input component: multi-line text input area for data entry
- [ ] Implement preview component: read-only output area with scrolling for live preview
- [ ] Implement split layout: left panel (categories) + right panel (input/output) arrangement
- [ ] Implement theme.zig: dark and light theme color schemes, theme switching with F3
- [ ] Write tests for key parsing, layout calculations, theme color mapping
- [ ] Run test suite - must pass before task 10

### Task 10: TUI command integration

**Files:**
- Modify: `src/core/tui.zig`
- Modify: `src/main.zig`

- [ ] Build the main TUI loop: render categories -> select command -> show input area -> live preview output -> copy result with F2
- [ ] Integrate command registry: execute selected command on input text, display result in preview panel
- [ ] Implement keyboard navigation: arrow keys for category/command selection, Tab to switch panels, Ctrl+C to exit
- [ ] Wire up TUI mode in main.zig when invoked without arguments
- [ ] Write tests for TUI state machine transitions
- [ ] Run test suite - must pass before task 11

### Task 11: Final verification and documentation

- [ ] Manual test: `echo '{"a":1}' | zuxi jsonfmt` produces formatted JSON
- [ ] Manual test: `zuxi base64 encode "hello"` outputs `aGVsbG8=`
- [ ] Manual test: `zuxi hash sha256 "test"` outputs known hash
- [ ] Manual test: `zuxi uuid generate` produces valid UUID
- [ ] Manual test: `zuxi` without args launches TUI
- [ ] Run full test suite: `zig build test`
- [ ] Verify binary size is under 15 MB
- [ ] Verify startup time is under 50ms
- [ ] Update README.md with usage examples and command reference
- [ ] Move this plan to `docs/plans/completed/`
