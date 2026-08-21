# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`libssh2-swift` is a Swift Package wrapper for SSH2 protocol and SFTP services. It provides high-level Swift APIs for SSH connections, authentication, and SFTP file operations while encapsulating the underlying C libraries (libssh2 and AWS-LC) as binary XCFrameworks.

The package is Swift 6 concurrency-safe, using the actor model throughout to ensure thread-safe operations during async socket/SFTP operations.

## Architecture

### Three-Layer Dependency Structure

1. **libssh2kit** (Binary XCFramework)
   - Pre-compiled static library containing merged libssh2, libssl, and libcrypto
   - Hosted as a GitHub Release asset (`.xcframework.zip`)
   - Referenced in `Package.swift` as a `.binaryTarget` with URL and checksum
   - Built from upstream libssh2 and AWS-LC sources

2. **Clibssh2** (C Module Wrapper)
   - Swift module that exposes libssh2 C APIs
   - Contains `module.modulemap` defining the `libssh2` system module
   - Headers in `Sources/Clibssh2/include/` (libssh2.h, libssh2_sftp.h, etc.)
   - Minimal shim.c for any required C glue code

3. **libssh2-swift** (High-Level Swift APIs)
   - Public Swift actors: `SSHSession` and `SFTPService`
   - Hides C pointer management, socket handling, and memory allocation
   - Provides Swift-native async/await interfaces

### Core Public APIs

- **SSHSession** (actor): Manages TCP sockets, SSH handshakes, authentication (password/public-key), terminal I/O via AsyncStream, and command execution
- **SFTPService** (actor): Operates on an authenticated SSHSession to list directories, upload, and download files
- **SSHAuth** (enum): `.password(String, remember: Bool)` or `.publicKey(path: String, passphrase: String?)`
- **HostKeyStatus** (enum): `.notFound` or `.mismatch` for Known Hosts validation

### Concurrency Model

All public APIs use Swift 6 strict concurrency:
- `SSHSession` and `SFTPService` are actors (isolated state)
- libssh2 process-wide initialization (`libssh2_init`/`libssh2_exit`) uses reference counting guarded by `NSLock` to prevent races across concurrent sessions
- Terminal output is delivered via `AsyncStream<Data>`

## Build Commands

### Standard Development

```bash
# Build the package
swift build

# Run tests (if present)
swift test

# Build in release mode
swift build -c release

# Clean build artifacts
swift package clean
```

### Building Upstream Dependencies Locally

If you need to rebuild the binary XCFramework from upstream sources:

```bash
# Build AWS-LC (specify version tag)
./scripts/build_awslc.sh v1.73.0

# Build libssh2 (uses AWS-LC from previous step)
./scripts/build_libssh2.sh

# Merge static libraries
libtool -static -o ThirdParty/lib/libssh2_merged.a \
  ThirdParty/lib/libssh2.a \
  ThirdParty/lib/libssl.a \
  ThirdParty/lib/libcrypto.a

# Create XCFramework
mkdir -p ThirdParty/libssh2kit_headers
cp ThirdParty/include/libssh2*.h ThirdParty/libssh2kit_headers/
cp ThirdParty/include/openssl/*.h ThirdParty/libssh2kit_headers/
xcodebuild -create-xcframework \
  -library ThirdParty/lib/libssh2_merged.a \
  -headers ThirdParty/libssh2kit_headers \
  -output ThirdParty/libssh2kit.xcframework

# Compute checksum for Package.swift
swift package compute-checksum ThirdParty/libssh2kit.xcframework.zip
```

## Automated Update Workflow

The repository uses GitHub Actions (`.github/workflows/auto_update.yml`) to automatically track and integrate upstream releases:

1. **Trigger**: Runs daily at 3 AM UTC, on push to main, or via manual workflow_dispatch
2. **Version Check**: Fetches latest release tags from libssh2/libssh2 and aws/aws-lc repos
3. **Comparison**: Compares against `upstream_libssh2.txt` and `upstream_awslc.txt`
4. **Build Pipeline** (if updates found):
   - Clones and builds AWS-LC with CMake
   - Clones and builds libssh2 with CMake (using AWS-LC as crypto backend)
   - Merges static libraries with libtool
   - Packages as XCFramework and zips it
   - Computes checksum with `swift package compute-checksum`
   - Bumps patch version (e.g., v1.3.2 → v1.3.3)
   - Updates `Package.swift` with new URL and checksum
   - Commits changes with `[skip ci]` flag
   - Creates GitHub Release with the XCFramework zip asset

### Version Tracking Files

- `upstream_libssh2.txt`: Current libssh2 version (e.g., `libssh2-1.11.1`)
- `upstream_awslc.txt`: Current AWS-LC version (e.g., `v1.73.0`)

These files are the source of truth for what's currently packaged in the binary target.

## Package.swift Structure

The `Package.swift` manifest uses Swift 6.0 tools version and targets macOS 15+. The critical section is the `.binaryTarget`:

```swift
.binaryTarget(
    name: "libssh2kit",
    url: "https://github.com/SteveShi/libssh2-swift/releases/download/v1.3.2/libssh2kit.xcframework.zip",
    checksum: "de4e66e91190fbc812c0a9fc80e086177dd180815bc4ada912fbd9f7c8e611b5"
)
```

When updating the binary:
1. The URL must point to a valid GitHub Release asset
2. The checksum must match exactly (computed via `swift package compute-checksum`)
3. The version tag in the URL must exist as a Git tag and GitHub Release

## Working with C Interop

When modifying the C module wrapper (`Clibssh2`):
- The `module.modulemap` defines which headers are exposed to Swift
- Headers must be present in `Sources/Clibssh2/include/`
- The binary XCFramework must contain matching header files
- Use `import libssh2` in Swift code to access C APIs

## Swift 6 Concurrency Patterns

When working with the actor-based APIs:
- All `SSHSession` and `SFTPService` methods are async and actor-isolated
- Use `await` when calling actor methods from outside the actor
- The `AsyncStream<Data>` from `connect()` delivers terminal output; consume it in a Task
- libssh2 C APIs are called from within actor isolation to ensure thread safety
- The `nonisolated(unsafe)` static storage for `initRefCount` is intentional and guarded by `NSLock`

## Platform Requirements

- **Minimum Platform**: macOS 15.0
- **Swift Version**: 6.0 (strict concurrency enabled)
- **Build Tools**: CMake, libtool, xcodebuild (for building upstream dependencies)

<!-- BEGIN brain.md -->
## Project Brain

This project keeps a **Project Brain**: a persistent memory layer of its durable decisions, requirements, and constraints. Read `./BRAIN.md` for the full read/write contract.
@import ./BRAIN.md

Maintain the brain as part of normal coding work — not as a separate task. While discussing or implementing features:
- **Start of a task:** load relevant context with the `brain` CLI (`list-pages`, `read-page`, `read-root`). Prefer a narrow read over scanning everything.
- **When a decision, requirement, constraint, or durable insight settles** (in chat or while coding): capture it immediately via the `brain` CLI. Do not wait to be asked and do not batch it for later.
- **Pure implementation with no new decision:** do not write to the brain.
- **When overturning a prior conclusion:** update the page (`update-truth` and/or `append-timeline` with `kind: reversal`, or `archive-page`).
- Only store what will still matter in six months and is hard to reconstruct from the code alone.
- All reads and writes go through the `brain` CLI — never hand-edit brain files.

The brain skills (`brain-setup`, `brain-page`, `brain-ingest`, `brain-bootstrap`) are installed in your global skills directory. Prefer `brain init` to scaffold a new project.
<!-- END brain.md -->
