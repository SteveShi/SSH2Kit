import Foundation
import Darwin
import CryptoKit
import libssh2

public enum HostKeyStatus: Sendable {
    case notFound(keyFingerprint: String)
    case mismatch(keyFingerprint: String)
}

public enum HostKeyFingerprint {
    /// SHA-256 fingerprint of a raw host key, OpenSSH style (base64, no padding).
    public static func sha256(of keyData: Data) -> String {
        let digest = SHA256.hash(data: keyData)
        let base64 = Data(digest).base64EncodedString()
        return "SHA256:" + base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

/// A thread-safe cooperative-cancellation flag. Set from any thread
/// (typically the main actor) to abort an in-flight blocking libssh2
/// operation via the socket I/O callbacks below.
final class SSHCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        value = false
        lock.unlock()
    }
}

/// User-data handed to libssh2 via `libssh2_session_init_ex` and dereferenced
/// by the send/recv callbacks. Must outlive the C session (held by the actor).
final class SSHCallbackContext: @unchecked Sendable {
    let cancelFlag: SSHCancelFlag
    var socketFD: Int32 = -1

    init(cancelFlag: SSHCancelFlag) {
        self.cancelFlag = cancelFlag
    }
}

// MARK: - C socket I/O callbacks
//
// Installed over the default libssh2 recv/send so that a cancellation request
// can interrupt blocking-mode calls (handshake, userauth, blocking reads):
// once the flag is set the next callback invocation fails the I/O, which
// makes libssh2 abort with a socket error instead of blocking until timeout.

private func sshkitSocketIO(
    recv: Bool,
    buf: UnsafeMutablePointer<UInt8>?,
    len: Int,
    flags: Int32,
    abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int {
    guard let abstract, let ptr = abstract.pointee else {
        errno = EIO
        return -1
    }
    let context = Unmanaged<SSHCallbackContext>.fromOpaque(ptr).takeUnretainedValue()
    if context.cancelFlag.isCancelled {
        errno = ECANCELED
        return -1
    }
    guard let buf, context.socketFD >= 0 else {
        errno = EBADF
        return -1
    }
    if recv {
        var result: Int
        repeat {
            result = Darwin.recv(context.socketFD, buf, len, flags)
        } while result < 0 && errno == EINTR
        return result
    } else {
        var result: Int
        repeat {
            result = Darwin.send(context.socketFD, buf, len, flags)
        } while result < 0 && errno == EINTR
        return result
    }
}

private let sshkitRecvCallback: @convention(c) (
    OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int, Int32,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int = { _, buf, len, flags, abstract in
    sshkitSocketIO(recv: true, buf: buf, len: len, flags: flags, abstract: abstract)
}

private let sshkitSendCallback: @convention(c) (
    OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int, Int32,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int = { _, buf, len, flags, abstract in
    sshkitSocketIO(recv: false, buf: buf, len: len, flags: flags, abstract: abstract)
}

public actor SSHSession {
    public enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    public private(set) var state: State = .disconnected

    public init() {}

    private var session: OpaquePointer?
    private var channel: OpaquePointer?
    private var socketFD: Int32 = -1
    private var outputContinuation: AsyncStream<Data>.Continuation?

    /// Cooperative-cancellation state for in-flight blocking operations.
    /// `cancelFlag` is accessed nonisolated so cancellation can be requested
    /// even while the actor is blocked inside a libssh2 C call.
    private let cancelFlag = SSHCancelFlag()
    private var callbackContext: SSHCallbackContext?

    /// Requests cancellation of any in-flight blocking operation (handshake,
    /// userauth, blocking channel I/O). Safe to call from any thread without
    /// awaiting the actor — that is the whole point.
    public nonisolated func cancelActiveOperation() {
        cancelFlag.cancel()
    }

    private func checkCancelled() throws {
        if cancelFlag.isCancelled || Task.isCancelled {
            throw SSHError.cancelled
        }
    }

    private var pendingHostKey: Data?
    private var pendingHostKeyType: Int32?
    private var pendingHost: String?
    private var pendingPort: Int?
    private var pendingHostStatus: HostKeyStatus?
    private var pendingUsername: String?

    /// libssh2_init / libssh2_exit reference counting (process-wide).
    /// libssh2 documents that init/exit must be balanced, and calling init
    /// concurrently across multiple sessions can race. The mutable count is
    /// guarded by `initLock` — `nonisolated(unsafe)` is required because
    /// actor-isolated `static` storage is otherwise unreachable from the lock-
    /// guarded helpers below under Swift 6 strict concurrency.
    nonisolated private static let initLock = NSLock()
    nonisolated(unsafe) private static var initRefCount: Int = 0

    private nonisolated static func libsshInit() throws {
        initLock.lock()
        defer { initLock.unlock() }
        if initRefCount == 0 {
            guard libssh2_init(0) == 0 else { throw SSHError.initializationFailed }
        }
        initRefCount += 1
    }

    private nonisolated static func libsshExit() {
        initLock.lock()
        defer { initLock.unlock() }
        guard initRefCount > 0 else { return }
        initRefCount -= 1
        if initRefCount == 0 {
            libssh2_exit()
        }
    }

    /// Internal escape hatch for in-package wrappers (`SFTPService`).
    /// Not public by design: raw C pointer access bypasses the actor's
    /// blocking-mode management, so it must stay inside this module.
    func withRawSession<T: Sendable>(_ body: @Sendable (OpaquePointer) throws -> T) throws -> T {
        guard let session else { throw SSHError.notConnected }
        libssh2_session_set_blocking(session, 1)
        defer { libssh2_session_set_blocking(session, 0) }
        return try body(session)
    }

    public func connect(host: String, port: Int, username: String, auth: SSHAuth, cols: Int = 80, rows: Int = 24) async throws -> AsyncStream<Data> {
        // Reentry guard: if a previous attempt left state inconsistent, clean up first.
        if session != nil || socketFD != -1 {
            await disconnect()
        }
        // A previous operation may have left the flag set (e.g. we cancelled a
        // stuck connect right before this one) — start from a clean slate now
        // that the actor is free.
        cancelFlag.reset()
        state = .connecting

        var didInit = false
        var localFD: Int32 = -1
        var localSession: OpaquePointer? = nil
        let context = SSHCallbackContext(cancelFlag: cancelFlag)
        self.callbackContext = context

        // Cleanup helper for the failure path — frees only what we acquired locally,
        // leaves no half-initialized resources behind in `self`.
        func rollback() {
            context.socketFD = -1
            if let s = localSession { libssh2_session_free(s) }
            if localFD != -1 { close(localFD) }
            if didInit { SSHSession.libsshExit() }
            self.session = nil
            self.socketFD = -1
            self.callbackContext = nil
            cancelFlag.reset()
            state = .disconnected
        }

        do {
            try checkCancelled()
            localFD = try openSocket(host: host, port: port)
            context.socketFD = localFD
            try checkCancelled()

            try SSHSession.libsshInit()
            didInit = true

            guard let s = libssh2_session_init_ex(nil, nil, nil, Unmanaged.passUnretained(context).toOpaque()) else {
                throw SSHError.sessionInitFailed
            }
            localSession = s

            // Route socket I/O through our callbacks so cancellation can
            // interrupt the blocking handshake below.
            let recvCB = unsafeBitCast(sshkitRecvCallback, to: UnsafeMutableRawPointer.self)
            let sendCB = unsafeBitCast(sshkitSendCallback, to: UnsafeMutableRawPointer.self)
            libssh2_session_callback_set(s, Int32(LIBSSH2_CALLBACK_RECV), recvCB)
            libssh2_session_callback_set(s, Int32(LIBSSH2_CALLBACK_SEND), sendCB)

            libssh2_session_set_blocking(s, 1)

            let handshake = libssh2_session_handshake(s, localFD)
            guard handshake == 0 else {
                if cancelFlag.isCancelled || Task.isCancelled { throw SSHError.cancelled }
                throw SSHError.handshakeFailed(handshake)
            }

            // Commit to `self` only once handshake succeeded.
            self.socketFD = localFD
            self.session = s
            pendingUsername = username

            let checkResult = try KnownHostsStore.check(session: s, host: host, port: port)
            switch checkResult {
            case .match:
                break
            case let .notFound(keyData, keyType), let .mismatch(keyData, keyType):
                let status: HostKeyStatus = if case .notFound = checkResult {
                    .notFound(keyFingerprint: HostKeyFingerprint.sha256(of: keyData))
                } else {
                    .mismatch(keyFingerprint: HostKeyFingerprint.sha256(of: keyData))
                }
                pendingHostKey = keyData
                pendingHostKeyType = keyType
                pendingHost = host
                pendingPort = port
                pendingHostStatus = status
                throw SSHError.hostKeyNotTrusted(status)
            }

            return try await authenticateAndOpenChannel(auth: auth, cols: cols, rows: rows)
        } catch SSHError.hostKeyNotTrusted(let status) {
            // Keep socket+session alive so the user can accept the key and continue.
            // The pending* fields are already populated above.
            throw SSHError.hostKeyNotTrusted(status)
        } catch {
            rollback()
            throw error
        }
    }

    public func acceptHostKeyAndConnect(auth: SSHAuth, cols: Int = 80, rows: Int = 24) async throws -> AsyncStream<Data> {
        guard let session,
              let host = pendingHost,
              let port = pendingPort,
              let keyData = pendingHostKey,
              let keyType = pendingHostKeyType,
              let status = pendingHostStatus
        else {
            throw SSHError.hostKeyUnavailable
        }
        let replace: Bool
        if case .mismatch = status {
            replace = true
        } else {
            replace = false
        }
        try KnownHostsStore.addOrReplace(session: session, host: host, port: port, keyData: keyData, keyType: keyType, replace: replace)
        pendingHostKey = nil
        pendingHostKeyType = nil
        pendingHost = nil
        pendingPort = nil
        pendingHostStatus = nil

        return try await authenticateAndOpenChannel(auth: auth, cols: cols, rows: rows)
    }

    public func send(_ data: Data) async throws {
        guard let channel else { throw SSHError.notConnected }
        var totalSent = 0
        while totalSent < data.count {
            let sent = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.bindMemory(to: Int8.self).baseAddress else { return 0 }
                return libssh2_channel_write_ex(channel, 0, base.advanced(by: totalSent), buffer.count - totalSent)
            }
            if sent == Int(LIBSSH2_ERROR_EAGAIN) {
                // Yield to the actor so other consumers (read loop, monitoring) can progress
                // without busy-spinning on the lock.
                try await Task.sleep(nanoseconds: 5_000_000)
                continue
            }
            if sent < 0 {
                throw SSHError.writeFailed(sent)
            }
            totalSent += sent
        }
    }

    public func resize(cols: Int, rows: Int) async {
        guard let channel else { return }
        _ = libssh2_channel_request_pty_size_ex(channel, Int32(cols), Int32(rows), 0, 0)
    }

    public func disconnect() async {
        // Interrupt any blocking operation that is wedging the actor.
        cancelFlag.cancel()
        outputContinuation?.finish()
        outputContinuation = nil

        if let channel {
            libssh2_channel_send_eof(channel)
            libssh2_channel_close(channel)
            libssh2_channel_free(channel)
        }
        self.channel = nil

        if let session {
            libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "Client disconnect", "")
            libssh2_session_free(session)
        }
        self.session = nil

        if socketFD != -1 {
            close(socketFD)
            socketFD = -1
        }
        if let context = callbackContext {
            context.socketFD = -1
        }
        callbackContext = nil

        pendingHostKey = nil
        pendingHostKeyType = nil
        pendingHost = nil
        pendingPort = nil
        pendingHostStatus = nil
        pendingUsername = nil

        SSHSession.libsshExit()
        cancelFlag.reset()
        state = .disconnected
    }

    public func executeCommand(_ command: String) async throws -> String {
        try withRawSession { sessionPtr in
            guard let channel = libssh2_channel_open_ex(
                sessionPtr,
                "session",
                UInt32("session".utf8.count),
                2 * 1024 * 1024,
                32_768,
                nil,
                0
            ) else {
                throw SSHError.channelOpenFailed
            }
            defer {
                libssh2_channel_free(channel)
            }

            let rc = libssh2_channel_process_startup(
                channel,
                "exec",
                UInt32("exec".utf8.count),
                command,
                UInt32(command.utf8.count)
            )
            guard rc == 0 else {
                throw SSHError.shellFailed(rc)
            }

            var resultData = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                    libssh2_channel_read_ex(channel, 0, rawBuffer.bindMemory(to: Int8.self).baseAddress, rawBuffer.count)
                }
                if bytesRead > 0 {
                    resultData.append(buffer, count: bytesRead)
                } else if bytesRead == 0 {
                    break
                } else {
                    // In blocking mode EAGAIN should not occur; any negative
                    // return is a hard error — surface it instead of silently
                    // truncating the output.
                    if bytesRead != Int(LIBSSH2_ERROR_EAGAIN) {
                        // Clean shutdown order: EOF -> close -> free (via defer).
                        libssh2_channel_send_eof(channel)
                        libssh2_channel_close(channel)
                        throw SSHError.readFailed(Int32(bytesRead))
                    }
                    break
                }
            }

            libssh2_channel_send_eof(channel)
            libssh2_channel_close(channel)

            return String(decoding: resultData, as: UTF8.self)
        }
    }


    private func tryAgentAuth(session: OpaquePointer, username: String) -> Bool {
        guard let agent = libssh2_agent_init(session) else { return false }
        defer { libssh2_agent_free(agent) }

        guard libssh2_agent_connect(agent) == 0 else { return false }
        defer { libssh2_agent_disconnect(agent) }

        guard libssh2_agent_list_identities(agent) == 0 else { return false }

        var identity: UnsafeMutablePointer<libssh2_agent_publickey>? = nil
        var prev: UnsafeMutablePointer<libssh2_agent_publickey>? = nil

        while libssh2_agent_get_identity(agent, &identity, prev) == 0 {
            if let identity {
                let rc = libssh2_agent_userauth(agent, username, identity)
                if rc == 0 {
                    return true
                }
            }
            prev = identity
        }
        return false
    }

    private func authenticateAndOpenChannel(auth: SSHAuth, cols: Int, rows: Int) async throws -> AsyncStream<Data> {
        guard let session else { throw SSHError.sessionInitFailed }
        guard let username = pendingUsername else { throw SSHError.sessionInitFailed }
        try checkCancelled()

        var authenticated = tryAgentAuth(session: session, username: username)
        try checkCancelled()

        if !authenticated {
            switch auth {
            case .password(let password, _):
                let userauth = libssh2_userauth_password_ex(session, username, UInt32(username.utf8.count), password, UInt32(password.utf8.count), nil)
                if userauth == 0 {
                    authenticated = true
                }

            case .publicKey(let path, let passphrase):
                let pubPath = path + ".pub"
                let hasPub = FileManager.default.fileExists(atPath: pubPath)
                // The passphrase buffer is passed to libssh2 from inside
                // withUnsafeBufferPointer — the pointer is only valid for the
                // duration of the closure (use-after-scope otherwise).
                let userauthResult: Int32
                if let passphrase {
                    userauthResult = passphrase.utf8CString.withUnsafeBufferPointer { ptr in
                        libssh2_userauth_publickey_fromfile_ex(
                            session,
                            username,
                            UInt32(username.utf8.count),
                            hasPub ? pubPath : nil,
                            path,
                            ptr.baseAddress
                        )
                    }
                } else {
                    userauthResult = libssh2_userauth_publickey_fromfile_ex(
                        session,
                        username,
                        UInt32(username.utf8.count),
                        hasPub ? pubPath : nil,
                        path,
                        nil
                    )
                }
                if userauthResult == 0 {
                    authenticated = true
                }
            }
        }

        guard authenticated else {
            if cancelFlag.isCancelled || Task.isCancelled { throw SSHError.cancelled }
            throw SSHError.authFailed(-16)
        }

        try checkCancelled()

        let windowSize: UInt32 = 2 * 1024 * 1024
        let packetSize: UInt32 = 32_768
        guard let channel = libssh2_channel_open_ex(
            session,
            "session",
            UInt32("session".utf8.count),
            windowSize,
            packetSize,
            nil,
            0
        ) else {
            throw SSHError.channelOpenFailed
        }
        self.channel = channel

        let ptyResult = libssh2_channel_request_pty_ex(channel, "xterm-256color", UInt32("xterm-256color".utf8.count), nil, 0, Int32(cols), Int32(rows), 0, 0)
        guard ptyResult == 0 else {
            throw SSHError.ptyFailed(ptyResult)
        }

        let shellResult = libssh2_channel_process_startup(
            channel,
            "shell",
            UInt32("shell".utf8.count),
            nil,
            0
        )
        guard shellResult == 0 else {
            throw SSHError.shellFailed(shellResult)
        }

        state = .connected
        libssh2_session_set_blocking(session, 0)
        return startReadingLoop()
    }

    private func setOutputContinuation(_ continuation: AsyncStream<Data>.Continuation) {
        self.outputContinuation = continuation
    }

    private func startReadingLoop() -> AsyncStream<Data> {
        AsyncStream { continuation in
            Task { [weak self] in
                await self?.setOutputContinuation(continuation)
                await self?.readLoop(continuation: continuation)
            }
        }
    }

    private func readLoop(continuation: AsyncStream<Data>.Continuation) async {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        // Adaptive backoff: idle period grows when nothing arrives,
        // shrinks immediately when data appears. Avoids a hot 10ms spin
        // while keeping latency low under load.
        var idleNanos: UInt64 = 2_000_000   // 2ms
        let maxIdle: UInt64 = 50_000_000    // 50ms
        while !Task.isCancelled {
            guard let channel else { break }
            let rc = buffer.withUnsafeMutableBytes { rawBuffer in
                libssh2_channel_read_ex(channel, 0, rawBuffer.bindMemory(to: Int8.self).baseAddress, rawBuffer.count)
            }
            if rc > 0 {
                let data = Data(buffer[0..<rc])
                continuation.yield(data)
                idleNanos = 2_000_000
                continue
            }
            if rc == 0 {
                // EOF only when channel really reports closed.
                if libssh2_channel_eof(channel) != 0 { break }
                // Otherwise treat as transient and back off.
                do { try await Task.sleep(nanoseconds: idleNanos) } catch { break }
                idleNanos = min(idleNanos * 2, maxIdle)
                continue
            }
            if rc == Int(LIBSSH2_ERROR_EAGAIN) {
                do { try await Task.sleep(nanoseconds: idleNanos) } catch { break }
                idleNanos = min(idleNanos * 2, maxIdle)
                continue
            }
            break
        }
        continuation.finish()
    }

    private func openSocket(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var result: UnsafeMutablePointer<addrinfo>?
        let portString = String(port)
        let status = getaddrinfo(host, portString, &hints, &result)
        guard status == 0, let result else {
            throw SSHError.resolutionFailed(String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(result) }

        // 15s connect timeout per address. The default kernel timeout
        // (~75s) makes the UI feel hung when the host is unreachable.
        var timeout = timeval(tv_sec: 15, tv_usec: 0)

        var current: UnsafeMutablePointer<addrinfo>? = result
        while let addrInfo = current?.pointee {
            let fd = socket(addrInfo.ai_family, addrInfo.ai_socktype, addrInfo.ai_protocol)
            if fd >= 0 {
                // Apply a send/recv timeout so a stalled peer can't wedge the actor.
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                // Disable Nagle to reduce input latency for an interactive shell.
                var one: Int32 = 1
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                // Enable TCP keepalive so half-open connections get detected.
                setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))

                let connectResult = Darwin.connect(fd, addrInfo.ai_addr, addrInfo.ai_addrlen)
                if connectResult == 0 {
                    return fd
                }
                close(fd)
            }
            current = addrInfo.ai_next
        }

        throw SSHError.connectionFailed
    }
}

public enum SSHError: LocalizedError {
    case initializationFailed
    case sessionInitFailed
    case handshakeFailed(Int32)
    case authFailed(Int32)
    case channelOpenFailed
    case ptyFailed(Int32)
    case shellFailed(Int32)
    case writeFailed(Int)
    case readFailed(Int32)
    case resolutionFailed(String)
    case connectionFailed
    case notConnected
    case knownHostsInitFailed
    case knownHostsCheckFailed(Int32)
    case knownHostsWriteFailed(Int32)
    case hostKeyUnavailable
    case hostKeyNotTrusted(HostKeyStatus)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .initializationFailed:
            return "libssh2 init failed"
        case .sessionInitFailed:
            return "libssh2 session init failed"
        case .handshakeFailed(let code):
            return "SSH handshake failed (\(code))"
        case .authFailed(let code):
            return "SSH auth failed (\(code))"
        case .channelOpenFailed:
            return "SSH channel open failed"
        case .ptyFailed(let code):
            return "SSH PTY request failed (\(code))"
        case .shellFailed(let code):
            return "SSH shell failed (\(code))"
        case .writeFailed(let code):
            return "SSH write failed (\(code))"
        case .readFailed(let code):
            return "SSH read failed (\(code))"
        case .resolutionFailed(let message):
            return "DNS resolution failed (\(message))"
        case .connectionFailed:
            return "Socket connection failed"
        case .notConnected:
            return "Not connected"
        case .knownHostsInitFailed:
            return "known_hosts init failed"
        case .knownHostsCheckFailed(let code):
            return "known_hosts check failed (\(code))"
        case .knownHostsWriteFailed(let code):
            return "known_hosts write failed (\(code))"
        case .hostKeyUnavailable:
            return "Host key unavailable"
        case .hostKeyNotTrusted(let status):
            switch status {
            case .notFound(let fingerprint):
                return "Host key not found (\(fingerprint)). Confirmation required."
            case .mismatch(let fingerprint):
                return "Host key mismatch (\(fingerprint)). Confirmation required."
            }
        case .cancelled:
            return "Operation cancelled"
        }
    }
}
