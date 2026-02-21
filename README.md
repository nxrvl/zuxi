# Zuxi

Cross-platform offline developer toolkit. A single static binary with CLI and TUI modes.

No telemetry. No external runtime dependencies.

## Install

### macOS (Homebrew)

```bash
brew install nxrvl/tap/zuxi
```

### Linux (Debian/Ubuntu)

```bash
# amd64
curl -LO https://github.com/nxrvl/zuxi/releases/latest/download/zuxi_VERSION_amd64.deb
sudo dpkg -i zuxi_VERSION_amd64.deb
```

### Linux (Fedora/RHEL)

```bash
# x86_64
curl -LO https://github.com/nxrvl/zuxi/releases/latest/download/zuxi-VERSION-1.x86_64.rpm
sudo rpm -i zuxi-VERSION-1.x86_64.rpm
```

### Binary download

Download from [Releases](https://github.com/nxrvl/zuxi/releases) — static binaries for macOS (arm64, amd64) and Linux (amd64, arm64).

### Build from source

Requires [Zig](https://ziglang.org/) 0.15+:

```bash
zig build -Doptimize=ReleaseSafe
# Binary at zig-out/bin/zuxi
```

## Usage

### CLI Mode

```bash
zuxi <command> [subcommand] [flags]
```

### TUI Mode

Launch the interactive terminal UI by running `zuxi` without arguments:

```bash
zuxi
```

Navigate with arrow keys, Tab to switch panels, F2 to copy output, F3 to toggle theme, Ctrl+C to exit.

### Global Flags

| Flag | Description |
|------|-------------|
| `--help`, `-h` | Show help |
| `--version`, `-v` | Show version |
| `--output <file>` | Write output to file |
| `--format json\|text` | Output format |
| `--no-color` | Disable colored output |
| `--quiet` | Suppress non-essential output |

## Commands

### JSON

```bash
# Format JSON (prettify)
echo '{"a":1,"b":2}' | zuxi jsonfmt

# Minify JSON
echo '{ "a": 1 }' | zuxi jsonfmt minify

# Validate JSON
echo '{"valid":true}' | zuxi jsonfmt validate
```

### Encoding

```bash
# Base64 encode/decode
zuxi base64 encode "hello world"
zuxi base64 decode "aGVsbG8gd29ybGQ="

# String case conversion
zuxi strcase snake "helloWorld"      # hello_world
zuxi strcase camel "hello_world"     # helloWorld
zuxi strcase pascal "hello_world"    # HelloWorld
zuxi strcase kebab "helloWorld"      # hello-world
zuxi strcase upper "hello world"     # HELLO WORLD
```

### Security

```bash
# Hash digests
zuxi hash sha256 "test"
zuxi hash sha512 "test"
zuxi hash md5 "test"
echo -n "file contents" | zuxi hash sha256

# JWT decode
zuxi jwt decode "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.signature"
```

### Time

```bash
# Show current time
zuxi time now

# Convert Unix timestamp to RFC3339
zuxi time unix 1700000000

# Convert RFC3339 to Unix timestamp
zuxi time rfc3339 "2023-11-14T22:13:20Z"
```

### Dev Tools

```bash
# Generate UUID v4
zuxi uuid generate

# Decode UUID
zuxi uuid decode "550e8400-e29b-41d4-a716-446655440000"

# HTTP requests
zuxi http GET https://httpbin.org/get
zuxi http POST https://httpbin.org/post --body '{"key":"value"}' --json
zuxi http GET https://example.com --header "Authorization: Bearer token"
```

## Build Options

```bash
zig build                          # Debug build
zig build -Doptimize=ReleaseSafe   # Release build
zig build -Dmode=lite              # Lite build (reduced features)
zig build test                     # Run tests
zig build run                      # Build and run
```

## Constraints

- Single static binary, cross-compiled
- Binary size: ~5 MB
- Startup time: <1ms
- No network dependencies except the `http` command

## License

MIT
