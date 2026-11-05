import Foundation

/// Read-only client for destiny.gg chat, with automatic reconnection.
///
/// DGG drops connections often, so `connect()` returns ONE long-lived stream
/// that survives reconnects: it keeps yielding events across drops rather than
/// finishing. Callers never need to re-subscribe.
public final class ChatClient: NSObject, @unchecked Sendable {

    public static let endpoint = URL(string: "wss://chat.destiny.gg/ws")!

    /// Reconnect if nothing arrives for this long. DGG carries ~400 msg/min,
    /// so prolonged silence means a dead socket, not a quiet room. A socket
    /// can die without the delegate ever firing, which is why this exists.
    public var silenceTimeout: TimeInterval = 45

    /// A destiny.gg Login Key, sent as the `authtoken` cookie. Chat treats a key
    /// it doesn't accept as a guest rather than refusing the connection.
    public var loginKey: String?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var continuation: AsyncStream<ChatEvent>.Continuation?

    private var keepAlive: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?

    private let lock = NSLock()
    private var running = false
    private var opened = false
    private var attempt = 0
    private var lastActivity = Date()
    /// Bumped on every socket. A cancelled socket's receive callback still
    /// fires a failure afterwards; without this it re-triggers the backoff and
    /// a reconnect that should take ~2s takes ~16s instead.
    private var generation = 0

    public override init() { super.init() }

    // MARK: - Lifecycle

    public func connect() -> AsyncStream<ChatEvent> {
        AsyncStream { cont in
            self.continuation = cont
            self.running = true
            self.attempt = 0
            self.open()
            cont.onTermination = { @Sendable _ in self.stop() }
        }
    }

    /// Permanently stop; the stream finishes and no reconnect is attempted.
    public func stop() {
        lock.lock(); running = false; lock.unlock()
        cancelTimers()
        reconnect?.cancel(); reconnect = nil
        teardownSocket()
        continuation?.finish()
    }

    /// Back-compat alias.
    public func disconnect() { stop() }

    /// Drop the socket WITHOUT stopping, to exercise the reconnect path.
    public func debugForceDrop() {
        lock.lock(); let gen = generation; lock.unlock()
        teardownSocket()
        noteDisconnect(reason: "forced drop (test)", gen: gen)
    }

    // MARK: - Socket

    private func open() {
        lock.lock()
        guard running else { lock.unlock(); return }
        lock.unlock()

        teardownSocket()

        var req = URLRequest(url: Self.endpoint)
        req.setValue("https://www.destiny.gg", forHTTPHeaderField: "Origin")
        req.setValue("DGGTV/0.1 (tvOS client)", forHTTPHeaderField: "User-Agent")
        if let key = loginKey, !key.isEmpty {
            req.setValue("authtoken=\(key)", forHTTPHeaderField: "Cookie")
        }

        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let t = s.webSocketTask(with: req)
        lock.lock()
        generation += 1
        let gen = generation
        lock.unlock()
        session = s
        task = t
        lastActivity = Date()
        t.resume()
        receiveLoop(gen)
        startTimers(gen)
    }

    private func teardownSocket() {
        cancelTimers()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    /// True only for the socket that is currently live.
    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen == generation
    }

    private func startTimers(_ gen: Int) {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, !Task.isCancelled, self.isCurrent(gen) else { return }
                self.task?.sendPing { _ in }
            }
        }

        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled, self.isCurrent(gen) else { return }
                let quiet = Date().timeIntervalSince(self.lastActivity)
                if quiet > self.silenceTimeout {
                    // Socket is alive as far as URLSession knows, but nothing
                    // is coming through. Treat it as dead.
                    self.teardownSocket()
                    self.noteDisconnect(reason: "silent for \(Int(quiet))s", gen: gen)
                    return
                }
            }
        }
    }

    private func cancelTimers() {
        keepAlive?.cancel(); keepAlive = nil
        watchdog?.cancel(); watchdog = nil
    }

    private func receiveLoop(_ gen: Int) {
        task?.receive { [weak self] result in
            guard let self, self.isCurrent(gen) else { return }
            switch result {
            case .failure(let err):
                self.teardownSocket()
                self.noteDisconnect(reason: err.localizedDescription, gen: gen)
            case .success(let msg):
                self.noteActivity()
                switch msg {
                case .string(let raw):
                    if let ev = FrameParser.parse(raw) { self.continuation?.yield(ev) }
                case .data(let d):
                    if let raw = String(data: d, encoding: .utf8),
                       let ev = FrameParser.parse(raw) { self.continuation?.yield(ev) }
                @unknown default: break
                }
                self.receiveLoop(gen)
            }
        }
    }

    // MARK: - State

    /// Traffic is the real proof we are connected — the didOpen delegate is
    /// not always delivered, which left the UI stuck on "connecting" while
    /// messages were visibly arriving.
    private func noteActivity() {
        lock.lock()
        lastActivity = Date()
        let wasClosed = !opened
        opened = true
        attempt = 0
        lock.unlock()
        if wasClosed { continuation?.yield(.connected) }
    }

    private func noteDisconnect(reason: String, gen: Int) {
        lock.lock()
        // Ignore the death rattle of a socket we already replaced.
        guard gen == generation else { lock.unlock(); return }
        let wasOpen = opened
        opened = false
        guard running else { lock.unlock(); return }
        attempt += 1
        let n = attempt
        lock.unlock()

        if wasOpen { continuation?.yield(.disconnected(reason: reason)) }

        // Exponential backoff with jitter, capped — DGG comes back quickly,
        // but don't hammer it during an outage.
        let delay = min(pow(2.0, Double(min(n, 5))), 30) + Double.random(in: 0...1)
        continuation?.yield(.reconnecting(attempt: n, inSeconds: delay))

        reconnect?.cancel()
        reconnect = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.open()
        }
    }

    /// The one thing this client can send, and only when the user picks an
    /// option. It deliberately has no way to post a chat message.
    public func vote(option: Int) {
        task?.send(.string("CASTVOTE {\"vote\":\"\(option)\"}")) { _ in }
    }
}

extension ChatClient: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession,
                           webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol proto: String?) {
        guard webSocketTask === task else { return }
        noteActivity()
    }

    public func urlSession(_ session: URLSession,
                           webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                           reason: Data?) {
        guard webSocketTask === task else { return }
        let why = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "code \(closeCode.rawValue)"
        lock.lock(); let gen = generation; lock.unlock()
        teardownSocket()
        noteDisconnect(reason: why, gen: gen)
    }
}
