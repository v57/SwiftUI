import Foundation

/// A thread that runs blocking jobs in order (one per connection, so a blocked receive never holds a shared
/// worker).
final class BlockingWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [() -> Void] = []
    private let signal = DispatchSemaphore(value: 0)
    private var stopped = false
    private var started = false
    private let name: String

    init(name: String) { self.name = name }

    func enqueue(_ job: @escaping () -> Void) {
        lock.lock()
        jobs.append(job)
        let start = !started
        started = true
        lock.unlock()
        if start {
            let thread = Thread { [self] in run() }
            thread.name = name
            thread.stackSize = 1 << 20
            thread.start()
        }
        signal.signal()
    }

    /// Ends the thread once the jobs queued so far ran.
    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        signal.signal()
    }

    private func run() {
        while true {
            signal.wait()
            lock.lock()
            if jobs.isEmpty {
                let done = stopped
                lock.unlock()
                if done { return }
                continue
            }
            let job = jobs.removeFirst()
            lock.unlock()
            job()
        }
    }
}

/// A connection to an endpoint: TCP (optionally under TLS) or a connected UDP socket.
public final class NWConnection: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case setup
        case waiting(NWError)
        case preparing
        case ready
        case failed(NWError)
        case cancelled
    }

    public final class ContentContext: @unchecked Sendable {
        public let identifier: String
        public let isFinal: Bool
        public init(identifier: String, expiration: UInt64 = 0, priority: Double = 0.5, isFinal: Bool = false, antecedent: ContentContext? = nil) {
            self.identifier = identifier
            self.isFinal = isFinal
        }
        public static let defaultMessage = ContentContext(identifier: "default")
        public static let finalMessage = ContentContext(identifier: "final", isFinal: true)
        public static let defaultStream = ContentContext(identifier: "stream")
    }

    public enum SendCompletion: Sendable {
        case contentProcessed(@Sendable (NWError?) -> Void)
        case idempotent
    }

    public let endpoint: NWEndpoint
    public let parameters: NWParameters
    public var stateUpdateHandler: (@Sendable (State) -> Void)? {
        get { lock.withLock { _stateUpdateHandler } }
        set { lock.withLock { _stateUpdateHandler = newValue } }
    }
    public var state: State { lock.withLock { _state } }
    public private(set) var queue: DispatchQueue?

    private let lock = NSLock()
    private var _stateUpdateHandler: (@Sendable (State) -> Void)?
    private var _state: State = .setup
    private var socket: Socket?
    private var accepted: Socket?
    private var tls: TLSSession?
    private var isCancelled = false
    private var buffer = Data()
    private var reachedEnd = false
    private let receiver = BlockingWorker(name: "NWConnection")
    /// Sends wait here until the connection is ready.
    private let sendQueue: DispatchQueue
    private var sendsHeld = true

    /// Lets the sends run (once ready, failed or cancelled). A suspended queue must not be released.
    private func releaseSends() {
        let resume = lock.withLock { () -> Bool in
            defer { sendsHeld = false }
            return sendsHeld
        }
        if resume { sendQueue.resume() }
    }

    public init(to endpoint: NWEndpoint, using parameters: NWParameters) {
        self.endpoint = endpoint
        self.parameters = parameters
        sendQueue = DispatchQueue(label: "NWConnection.send")
        sendQueue.suspend()
    }

    public convenience init(host: NWEndpoint.Host, port: NWEndpoint.Port, using parameters: NWParameters) {
        self.init(to: .hostPort(host: host, port: port), using: parameters)
    }

    /// A connection a listener accepted.
    init(accepted socket: Socket, parameters: NWParameters) {
        endpoint = socket.peer() ?? .hostPort(host: "0.0.0.0", port: 0)
        self.parameters = parameters
        accepted = socket
        sendQueue = DispatchQueue(label: "NWConnection.send")
        sendQueue.suspend()
    }

    public var currentPath: NWPath? { nil }

    deinit {
        (socket ?? accepted)?.close()
        receiver.stop()
        if sendsHeld { sendQueue.resume() }
    }

    public func start(queue: DispatchQueue) {
        lock.lock()
        guard self.queue == nil else { lock.unlock(); return }
        self.queue = queue
        lock.unlock()
        update(.preparing)
        receiver.enqueue { [self] in establish() }
    }

    private func establish() {
        do {
            if let accepted {
                lock.withLock { socket = accepted }
            } else {
                guard case let .hostPort(host, port) = endpoint else { throw NWError.posix(.EAFNOSUPPORT) }
                let name: String = switch host {
                case .name(let name, _): name
                case .ipv4(let address): address.debugDescription
                case .ipv6(let address): address.debugDescription
                }
                let addresses = try Socket.resolve(name, port: port.rawValue, udp: parameters.isUDP)
                let socket = try Socket.connect(
                    to: addresses, udp: parameters.isUDP, noDelay: parameters.tcpOptions?.noDelay ?? false,
                    cancelled: { lock.withLock { isCancelled } },
                    current: { socket in lock.withLock { self.socket = socket } })
                if let options = parameters.tls?.securityProtocolOptions {
                    let session = try TLSSession.connect(socket: socket, serverName: options.serverName ?? name, options: options)
                    lock.withLock { tls = session }
                }
            }
            if lock.withLock({ isCancelled }) { throw NWError.posix(.ECANCELED) }
            update(.ready)
            releaseSends()
        } catch {
            let error = error as? NWError ?? .posix(.EIO)
            if lock.withLock({ isCancelled }) { return }
            update(.failed(error))
            socket?.close()
            releaseSends()
        }
    }

    private func update(_ state: State) {
        lock.lock()
        if case .cancelled = _state { lock.unlock(); return }
        _state = state
        let handler = _stateUpdateHandler
        let queue = self.queue
        lock.unlock()
        if let handler, let queue { queue.async { handler(state) } }
    }

    public func cancel() {
        lock.lock()
        guard !isCancelled else { lock.unlock(); return }
        isCancelled = true
        let socket = self.socket ?? accepted
        let wasStarted = queue != nil
        lock.unlock()
        socket?.close()
        releaseSends()
        if wasStarted {
            update(.cancelled)
            receiver.stop()
        } else {
            lock.withLock { _state = .cancelled }
        }
    }

    public func forceCancel() { cancel() }
    public func restart() {}

    // MARK: Sending

    public func send(content: Data?, contentContext: ContentContext = .defaultMessage, isComplete: Bool = true, completion: SendCompletion) {
        sendQueue.async { [self] in
            var failure: NWError?
            lock.lock()
            let socket = self.socket
            let tls = self.tls
            let state = _state
            lock.unlock()
            if state != .ready {
                failure = .posix(.ENOTCONN)
                if case .failed(let error) = state { failure = error }
                if state == .cancelled { failure = .posix(.ECANCELED) }
            } else if let content, !content.isEmpty, let socket {
                do {
                    try socket.send(tls.map { try $0.encrypt(content) } ?? content)
                } catch {
                    failure = error as? NWError ?? .posix(.EIO)
                }
            }
            if case .contentProcessed(let done) = completion, let queue {
                let failure = failure
                queue.async { done(failure) }
            }
        }
    }

    // MARK: Receiving

    public func receive(
        minimumIncompleteLength: Int, maximumLength: Int,
        completion: @escaping @Sendable (Data?, ContentContext?, Bool, NWError?) -> Void
    ) {
        receiver.enqueue { [self] in
            var result: (Data?, ContentContext?, Bool, NWError?)
            do {
                guard state == .ready else { throw state == .cancelled ? NWError.posix(.ECANCELED) : NWError.posix(.ENOTCONN) }
                while buffer.count < max(minimumIncompleteLength, 1) && !reachedEnd {
                    let chunk = try read()
                    if chunk.isEmpty { reachedEnd = true } else { buffer.append(chunk) }
                }
                let count = min(buffer.count, maximumLength)
                let data = buffer.prefix(count)
                buffer.removeFirst(count)
                let complete = reachedEnd && buffer.isEmpty
                result = (data.isEmpty ? nil : Data(data), .defaultStream, complete, nil)
            } catch {
                result = (nil, nil, false, error as? NWError ?? .posix(.EIO))
            }
            deliver(result, completion)
        }
    }

    /// One datagram (UDP), or what the stream has (TCP).
    public func receiveMessage(completion: @escaping @Sendable (Data?, ContentContext?, Bool, NWError?) -> Void) {
        guard parameters.isUDP else {
            receive(minimumIncompleteLength: 1, maximumLength: 1 << 16, completion: completion)
            return
        }
        receiver.enqueue { [self] in
            var result: (Data?, ContentContext?, Bool, NWError?)
            do {
                guard state == .ready, let socket = lock.withLock({ self.socket }) else { throw NWError.posix(.ENOTCONN) }
                let data = try socket.receive(maximum: 65_536)
                result = (data, .defaultMessage, true, nil)
            } catch {
                result = (nil, nil, false, error as? NWError ?? .posix(.EIO))
            }
            deliver(result, completion)
        }
    }

    private func read() throws -> Data {
        guard let socket = lock.withLock({ self.socket }) else { throw NWError.posix(.ENOTCONN) }
        if let tls = lock.withLock({ self.tls }) {
            return try tls.decrypt { try socket.receive(maximum: 65_536) }
        }
        return try socket.receive(maximum: 65_536)
    }

    private func deliver(_ result: (Data?, ContentContext?, Bool, NWError?), _ completion: @escaping @Sendable (Data?, ContentContext?, Bool, NWError?) -> Void) {
        let queue = lock.withLock { self.queue } ?? .global()
        nonisolated(unsafe) let result = result
        queue.async { completion(result.0, result.1, result.2, result.3) }
    }
}

/// The path a connection takes (not tracked here).
public final class NWPath: @unchecked Sendable {
    public enum Status: Sendable { case satisfied, unsatisfied, requiresConnection }
    public var status: Status { .satisfied }
}

/// Listens for TCP connections on a port.
public final class NWListener: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case setup
        case waiting(NWError)
        case ready
        case failed(NWError)
        case cancelled
    }

    public let parameters: NWParameters
    public var stateUpdateHandler: (@Sendable (State) -> Void)?
    public var newConnectionHandler: (@Sendable (NWConnection) -> Void)?
    public private(set) var port: NWEndpoint.Port?

    private let requestedPort: UInt16
    private let lock = NSLock()
    private var socket: Socket?
    private var isCancelled = false

    public init(using parameters: NWParameters, on port: NWEndpoint.Port = .any) throws {
        guard !parameters.isUDP else { throw NWError.posix(.EPROTONOSUPPORT) }
        self.parameters = parameters
        requestedPort = port.rawValue
    }

    public func start(queue: DispatchQueue) {
        let thread = Thread { [self] in
            let socket: Socket
            do {
                let (listening, port) = try Socket.listen(port: requestedPort, reuse: parameters.allowLocalEndpointReuse)
                socket = listening
                lock.withLock {
                    self.socket = socket
                    self.port = NWEndpoint.Port(integerLiteral: port)
                }
            } catch {
                let error = error as? NWError ?? .posix(.EIO)
                queue.async { self.stateUpdateHandler?(.failed(error)) }
                return
            }
            queue.async { self.stateUpdateHandler?(.ready) }
            while true {
                do {
                    let client = try socket.accept()
                    let connection = NWConnection(accepted: client, parameters: parameters)
                    queue.async { self.newConnectionHandler?(connection) }
                } catch {
                    let cancelled = lock.withLock { isCancelled }
                    queue.async { self.stateUpdateHandler?(cancelled ? .cancelled : .failed(error as? NWError ?? .posix(.EIO))) }
                    return
                }
            }
        }
        thread.name = "NWListener"
        thread.start()
    }

    public func cancel() {
        let socket = lock.withLock { () -> Socket? in
            isCancelled = true
            return self.socket
        }
        socket?.close()
    }
}
