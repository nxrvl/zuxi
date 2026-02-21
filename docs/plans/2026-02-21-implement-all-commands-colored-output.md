# Implement all commands from docs/commands.md + colored output

## Overview

Implement all remaining commands from docs/commands.md (36 new commands) and add ANSI color output support.
Commands span text processing, format conversions (JSON/YAML/TOML/XML), CSS/HTML/GraphQL formatting, CSV/TSV tools,
security utilities, dev helpers, and more. Colored output applies to JSON prettify, JWT decode, HTTP responses, and
other formatted outputs.

## Context

- Files involved: all files under src/commands/, src/core/, src/main.zig, build.zig
- Currently implemented: jsonfmt, base64, strcase, hash, jwt, time, uuid, http
- Related patterns: every command is a self-contained .zig file with execute function, command struct, and tests
- Dependencies: none external; YAML/TOML/XML parsers built from scratch in src/formats/

## Development Approach

- **Testing approach**: Regular (code first, then tests)
- Complete each task fully before moving to the next
- Follow existing command patterns (execute fn, command struct, execWithInput test helper)
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: ANSI color output infrastructure

**Files:**
- Create: `src/core/color.zig`
- Modify: `src/main.zig` (add comptime test reference)

- [x] Create color.zig with ANSI escape code constants and helper functions
  - Color constants: red, green, blue, yellow, cyan, magenta, white, gray, bold, dim, reset
  - `colorize(writer, text, color_code, no_color: bool)` - write colored text
  - `shouldColor(ctx)` - return false if --no-color or stdout is not a TTY
  - JSON-specific: `writeColoredJson(writer, json_str, no_color)` - syntax highlight JSON (keys=cyan, strings=green, numbers=yellow, booleans=magenta, null=gray, braces=white)
- [x] Add comptime reference in main.zig for test discovery
- [x] Write tests for color.zig (colorize output, shouldColor logic, JSON colorization)
- [x] Run project test suite - must pass before task 2

### Task 2: Apply colored output to existing commands

**Files:**
- Modify: `src/commands/json/jsonfmt.zig`
- Modify: `src/commands/security/jwt.zig`
- Modify: `src/commands/dev/http.zig`

- [x] jsonfmt prettify: use writeColoredJson for colored JSON output when TTY and no --no-color
- [x] jwt decode: color section headers (bold), timestamp labels (cyan), EXPIRED (red), NOT EXPIRED (green)
- [x] http: color status line (green 2xx, yellow 3xx, red 4xx/5xx), header names (cyan), JSON body colored
- [x] Update existing tests to verify no regression; add tests with no_color=true/false
- [x] Run project test suite - must pass before task 3

### Task 3: Text commands - count, slug, urlencode

**Files:**
- Create: `src/commands/encoding/count.zig`
- Create: `src/commands/encoding/slug.zig`
- Create: `src/commands/encoding/urlencode.zig`
- Modify: `src/main.zig`

- [x] count: count characters, words, lines from input text
  - Default (no subcommand): show all stats
  - Input from positional arg or stdin
- [x] slug: convert text to URL-friendly slug
  - Lowercase, replace spaces/special chars with hyphens, strip non-ASCII
  - Basic transliteration for Cyrillic characters
- [x] urlencode: URL percent-encoding
  - Subcommands: encode (default), decode
  - RFC 3986 compliant encoding
- [x] Register all 3 commands in main.zig
- [x] Write tests for all 3 commands
- [x] Run project test suite - must pass before task 4

### Task 4: numbers (base converter) + hmac

**Files:**
- Create: `src/commands/dev/numbers.zig`
- Create: `src/commands/security/hmac.zig`
- Modify: `src/main.zig`

- [x] numbers: convert between binary, octal, decimal, hex
  - Auto-detect input base from prefix (0x, 0b, 0o) or assume decimal
  - Subcommands: bin, oct, dec, hex, all (default - show all bases)
- [x] hmac: compute HMAC signatures
  - Subcommands: sha256 (default), sha512
  - Flag: --key <secret> (passed as positional arg after data)
  - Input from positional arg or stdin
- [x] Register commands in main.zig
- [x] Write tests with known values
- [x] Run project test suite - must pass before task 5

### Task 5: Time tools - cron parser

**Files:**
- Create: `src/commands/time/cron.zig`
- Modify: `src/main.zig`

- [x] cron: parse and explain cron expressions
  - Parse standard 5-field cron (minute hour dom month dow)
  - Output human-readable description
  - Show next 5 scheduled run times
  - Support common patterns: */N, ranges (1-5), lists (1,3,5), special strings (@daily, @hourly)
- [x] Register command
- [x] Write tests for common cron expressions
- [x] Run project test suite - must pass before task 6

### Task 6: JSON toolkit - jsonrepair, jsonpath, jsonstruct

**Files:**
- Create: `src/commands/json/jsonrepair.zig`
- Create: `src/commands/json/jsonpath.zig`
- Create: `src/commands/json/jsonstruct.zig`
- Modify: `src/main.zig`

- [x] jsonrepair: fix common broken JSON issues
  - Fix: trailing commas, single quotes -> double quotes, unquoted keys, JS comments removal
  - Output repaired JSON or error if unrepairable
- [x] jsonpath: query JSON with dot-notation paths
  - Support: $.key, $.nested.key, $.array[0], $.array[*].field
  - Output matching value(s) with colored JSON
- [x] jsonstruct: generate Go struct from JSON
  - Infer Go types from JSON values
  - Nested objects -> nested structs
  - PascalCase field names, json struct tags
- [x] Register all 3 commands
- [x] Write tests for each command
- [x] Run project test suite - must pass before task 7

### Task 7: YAML parser + yamlfmt + yamlstruct

**Files:**
- Create: `src/formats/yaml.zig` (parser + serializer)
- Create: `src/commands/json/yamlfmt.zig`
- Create: `src/commands/json/yamlstruct.zig`
- Modify: `src/main.zig`

- [x] Implement YAML parser: scalars, mappings, sequences, nested structures, comments, quoted strings, multi-line (| and >)
- [x] Implement YAML serializer (internal representation -> YAML text)
- [x] yamlfmt: parse YAML, re-serialize with consistent 2-space indentation
- [x] yamlstruct: parse YAML -> generate Go struct (reuse jsonstruct logic)
- [x] Register both commands
- [x] Write parser unit tests + command tests
- [x] Run project test suite - must pass before task 8

### Task 8: TOML parser + tomlfmt

**Files:**
- Create: `src/formats/toml.zig`
- Create: `src/commands/json/tomlfmt.zig`
- Modify: `src/main.zig`

- [x] Implement TOML parser: key-value pairs, tables, arrays, arrays of tables, strings, integers, floats, booleans, datetime, inline tables, comments
- [x] Implement TOML serializer
- [x] tomlfmt: parse and re-format with consistent style
- [x] Register command
- [x] Write parser tests + command tests
- [x] Run project test suite - must pass before task 9

### Task 9: XML parser + xmlfmt

**Files:**
- Create: `src/formats/xml.zig`
- Create: `src/commands/json/xmlfmt.zig`
- Modify: `src/main.zig`

- [x] Implement XML parser: elements, attributes, text content, self-closing tags, comments, CDATA, XML declaration
- [x] Implement XML serializer (pretty-print with indentation)
- [x] xmlfmt: parse and re-format XML with consistent indentation
- [x] Register command
- [x] Write parser tests + command tests
- [x] Run project test suite - must pass before task 10

### Task 10: Format conversions - all 8 conversion commands

**Files:**
- Create: `src/commands/json/json2yaml.zig`
- Create: `src/commands/json/yaml2json.zig`
- Create: `src/commands/json/json2toml.zig`
- Create: `src/commands/json/toml2json.zig`
- Create: `src/commands/json/json2xml.zig`
- Create: `src/commands/json/xml2json.zig`
- Create: `src/commands/json/yaml2toml.zig`
- Create: `src/commands/json/toml2yaml.zig`
- Modify: `src/main.zig`

- [x] Create shared conversion layer using std.json.Value as intermediate representation
- [x] Implement all 8 conversion commands: json2yaml, yaml2json, json2toml, toml2json, json2xml, xml2json, yaml2toml, toml2yaml
- [x] Each command: parse source format -> intermediate -> serialize target format
- [x] Register all 8 commands
- [x] Write roundtrip tests for each conversion pair
- [x] Run project test suite - must pass before task 11

### Task 11: CSV/TSV tools - csv2json, csv2md, tsv2md

**Files:**
- Create: `src/commands/docs/csv.zig` (shared CSV/TSV parser)
- Create: `src/commands/docs/csv2json.zig`
- Create: `src/commands/docs/csv2md.zig`
- Create: `src/commands/docs/tsv2md.zig`
- Modify: `src/main.zig`

- [x] Implement CSV parser: handle quoted fields, escaped quotes, commas in fields
- [x] csv2json: CSV -> JSON array of objects (first row = headers)
- [x] csv2md: CSV -> Markdown table with alignment
- [x] tsv2md: TSV -> Markdown table (tab-separated variant)
- [x] Register all 3 commands
- [x] Write tests
- [x] Run project test suite - must pass before task 12

### Task 12: Web format tools - cssfmt, cssmin, htmlfmt, gqlquery

**Files:**
- Create: `src/commands/docs/cssfmt.zig`
- Create: `src/commands/docs/cssmin.zig`
- Create: `src/commands/docs/htmlfmt.zig`
- Create: `src/commands/docs/gqlquery.zig`
- Modify: `src/main.zig`

- [x] cssfmt: format CSS (brace/semicolon-level parsing, re-indent rules, one property per line)
- [x] cssmin: minify CSS (strip comments, collapse whitespace, remove unnecessary semicolons)
- [x] htmlfmt: format HTML (tag-level parsing, re-indent nested tags, preserve inline content)
- [x] gqlquery: format GraphQL queries (brace/paren-level parsing, re-indent)
- [x] Register all 4 commands
- [x] Write tests with sample CSS/HTML/GraphQL inputs
- [x] Run project test suite - must pass before task 13

### Task 13: Network/URL tools - urls, ports

**Files:**
- Create: `src/commands/dev/urls.zig`
- Create: `src/commands/dev/ports.zig`
- Modify: `src/main.zig`

- [x] urls: extract URLs from text
  - Default: find all URLs matching http(s)://... pattern
  - Subcommand: strict (validate URL structure)
- [x] ports: list listening network ports
  - Cross-platform: parse /proc/net/tcp on Linux, lsof/netstat on macOS
  - Show port, PID, process name
  - Filter by port number via positional arg
- [x] Register commands
- [x] Write tests
- [x] Run project test suite - must pass before task 14

### Task 14: Dev tools - envfile, serve, scaffold

**Files:**
- Create: `src/commands/dev/envfile.zig`
- Create: `src/commands/dev/serve.zig`
- Create: `src/commands/dev/scaffold.zig`
- Modify: `src/main.zig`

- [ ] envfile: .env file tools
  - Subcommands: validate (check syntax), to-json (convert to JSON), to-yaml (convert to YAML)
  - Parse KEY=VALUE format, handle comments, quoted values
- [ ] serve: simple static HTTP file server
  - Serve files from current directory or --dir path
  - Default port 8080, configurable via --port
  - Log requests to stderr
- [ ] scaffold: micro-template generator
  - Subcommands: env (generate .env template), compose (docker-compose.yml template)
  - Basic templates with common structure
- [ ] Register commands
- [ ] Write tests (envfile parsing, scaffold output verification)
- [ ] Run project test suite - must pass before task 15

### Task 15: Generator tools - gitignore, license, iban

**Files:**
- Create: `src/commands/dev/gitignore.zig`
- Create: `src/commands/dev/license.zig`
- Create: `src/commands/dev/iban.zig`
- Modify: `src/main.zig`

- [ ] gitignore: generate .gitignore from built-in templates
  - Templates: go, node, python, rust, zig, macos, linux, windows, vscode, jetbrains
  - Combine multiple: zuxi gitignore go,macos,vscode
- [ ] license: generate license text
  - Templates: mit, apache2, gpl3, bsd2, bsd3, unlicense
  - Flags: --author, --year (defaults to current year)
- [ ] iban: IBAN validation and generation
  - Subcommands: validate, generate
  - ISO 13616 check digit validation
  - Country code support for common countries
- [ ] Register commands
- [ ] Write tests
- [ ] Run project test suite - must pass before task 16

### Task 16: Verify acceptance criteria

- [ ] manual test: zuxi jsonfmt prettify '{"key":"value"}' produces colored output on TTY
- [ ] manual test: zuxi jsonfmt prettify --no-color produces plain output
- [ ] manual test: echo '{"a":1}' | zuxi jsonfmt produces uncolored output (pipe detection)
- [ ] manual test: all new commands appear in zuxi --help grouped by category
- [ ] manual test: spot-check 5+ commands end-to-end (count, urlencode, cron, csv2md, gitignore)
- [ ] run full test suite: zig build test
- [ ] verify build succeeds: zig build

### Task 17: Update documentation

- [ ] update CLAUDE.md if internal patterns changed (new src/formats/ directory, new categories)
- [ ] move this plan to `docs/plans/completed/`
