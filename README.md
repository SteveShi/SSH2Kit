# SSH2Kit

[中文版](README_zh.md)

`SSH2Kit` is a highly cohesive Swift Package wrapper for the **SSH2 protocol and SFTP services**.

It encapsulates the underlying C static libraries (`libssh2` and `AWS-LC`/`openssl` components) and headers as binary XCFrameworks, providing high-level Swift APIs for socket connection, credential verification, Known Hosts validation, and directory/file stream manipulations via SFTP.

---

## Core Features

1. **Remote Binary Resolution**: Underlying C frameworks (`libssh2`, `libssl`, `libcrypto`, and `libtls`) are resolved on-demand via SPM's remote `.binaryTarget` from GitHub Release zip assets, keeping the repository extremely lightweight.
2. **Swift 6 Concurrency Safe**: Conforms strictly to Swift 6 Concurrency specifications using the `actor` model and `Sendable` validation, ensuring thread-safe data operations during async socket/SFTP operations.
3. **Decoupled Architecture**: Fully hides socket handling, C pointer allocations, and memory freeing under neat, strong-typed Swift wrappers.
4. **Known Hosts Storage**: Integrated fingerprint storage and host verification API to secure SSH handshakes.

---

## Dependencies

Add this package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/SteveShi/SSH2Kit.git", from: "1.3.12")
]
```

And depend on `"SSH2Kit"` in your targets.

---

## Core APIs & Interface Descriptions

### 1. `SSHSession` (Actor)
Manages establishing TCP sockets, performing SSH handshakes, executing password/public-key authentications, and maintaining channel buffers.

```swift
public actor SSHSession {
    public enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    public private(set) var state: State

    public init()

    /// Connects to the host and performs SSH handshakes, returning an AsyncStream of terminal output data
    public func connect(host: String, port: Int, username: String, auth: SSHAuth, cols: Int = 80, rows: Int = 24) async throws -> AsyncStream<Data>

    /// Accepts an untrusted host key and connects
    public func acceptHostKeyAndConnect(auth: SSHAuth, cols: Int = 80, rows: Int = 24) async throws -> AsyncStream<Data>

    /// Sends input data to the SSH session
    public func send(_ data: Data) async throws

    /// Request a virtual terminal (PTY) resize
    public func resize(cols: Int, rows: Int) async

    /// Closes socket channel and frees C pointer handles
    public func disconnect() async

    /// Executes a single command on the remote host and returns stdout
    public func executeCommand(_ command: String) async throws -> String
}
```

### 2. `SFTPService` (Actor)
Operates on an authenticated `SSHSession` to open SFTP sub-systems for transferring files and directory lookups.

```swift
public actor SFTPService {
    /// Initializer taking an established SSHSession instance
    public init(session: SSHSession)
    
    /// List file attributes inside a directory
    public func list(path: String) async throws -> [SFTPItem]
    
    /// Download file from remote path to local URL
    public func download(remotePath: String, localURL: URL) async throws
    
    /// Upload file from local URL to remote path
    public func upload(localURL: URL, remotePath: String) async throws
}
```

### 3. Other Public Declarations

```swift
public enum HostKeyStatus: Sendable {
    case notFound
    case mismatch
}

public enum SSHAuth: Sendable {
    case password(String, remember: Bool)
    case publicKey(path: String, passphrase: String?)
}

public struct SFTPItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: UInt64?
}
```
