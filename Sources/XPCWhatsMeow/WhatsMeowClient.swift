import Foundation
import XPCWhatsMeowProtocol

/// WhatsApp, through the XPC service.
///
/// ```swift
/// let whatsApp = WhatsMeowClient()
/// try await whatsApp.start(WhatsMeowStartOptions(databasePath: path, deviceName: "My App")) { event in
///     // QR codes, messages, receipts, connection changes…
/// }
/// let session = try await whatsApp.startPairing()
/// ```
///
/// One client per app. The service holds one live connection per linked account, and a
/// second client — in another process, say — would be a second connection on the same
/// links, which WhatsApp resolves by disconnecting one of them.
///
/// If the service dies, the client restarts it with the same options, re-links its event
/// handler, and reports `.serviceRestarted`.
public final class WhatsMeowClient: @unchecked Sendable {
    private let makeConnection: @Sendable () -> NSXPCConnection
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var options: WhatsMeowStartOptions?
    private var onEvent: (@Sendable (WhatsMeowEvent) -> Void)?
    private var restartAttempt = 0
    private let receiver = EventReceiver()

    /// Connects to the service embedded in this app's `Contents/XPCServices`.
    public convenience init(serviceName: String = WhatsMeowXPC.defaultServiceName) {
        self.init(makeConnection: { NSXPCConnection(serviceName: serviceName) })
    }

    /// Connects to a listener endpoint — an anonymous listener in tests, or a service
    /// hosted some other way.
    public convenience init(endpoint: NSXPCListenerEndpoint) {
        self.init(makeConnection: { NSXPCConnection(listenerEndpoint: endpoint) })
    }

    init(makeConnection: @escaping @Sendable () -> NSXPCConnection) {
        self.makeConnection = makeConnection
        receiver.client = self
    }

    // MARK: - Lifecycle

    /// Starts the service's library and connects every account already linked in the
    /// session database. `onEvent` is called for every event, in order, on a private queue.
    public func start(_ options: WhatsMeowStartOptions, onEvent: @escaping @Sendable (WhatsMeowEvent) -> Void) async throws {
        lock.withLock {
            self.options = options
            self.onEvent = onEvent
            self.restartAttempt = 0
        }
        _ = try WhatsMeowEnvelope.result(try await sendStart(options))
    }

    /// Disconnects every account and lets the service exit.
    public func stop() async {
        let connection = lock.withLock { () -> NSXPCConnection? in
            options = nil
            onEvent = nil
            defer { self.connection = nil }
            return self.connection
        }
        guard let connection else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                once.run { continuation.resume() }
            } as? WhatsMeowServiceProtocol
            guard let proxy else { once.run { continuation.resume() }; return }
            proxy.stop { once.run { continuation.resume() } }
        }
        connection.invalidate()
    }

    // MARK: - Raw operations

    /// Runs one operation by name with JSON arguments and returns the JSON of its result.
    /// The typed methods below are built on this; see docs/Protocol.md for every method.
    public func call(_ method: String, arguments: Data) async throws -> Data {
        let envelope = try await send { proxy, reply in
            proxy.call(method: method, arguments: arguments, reply: reply)
        }
        return try WhatsMeowEnvelope.result(envelope)
    }

    public func call<Result: Decodable>(
        _ method: String, _ arguments: some Encodable, as: Result.Type = Result.self
    ) async throws -> Result {
        let data = try await call(method, arguments: try JSONEncoder().encode(arguments))
        do {
            return try JSONDecoder().decode(Result.self, from: data)
        } catch {
            throw WhatsMeowError(code: "decoding", message: "Unexpected reply to \(method): \(error.localizedDescription)")
        }
    }

    // MARK: - Accounts and pairing

    public func accounts() async throws -> [WhatsMeowAccount] {
        try await call("accounts", Empty())
    }

    /// Starts linking a new account and returns the pairing session id. QR codes arrive as
    /// `.pairQR` events; with `phone` (international format), a code to type on that phone
    /// arrives as `.pairCode` instead. The session ends with `.pairSuccess` or `.pairFailed`.
    public func startPairing(phone: String? = nil) async throws -> String {
        struct Args: Encodable { let phone: String? }
        struct Result: Decodable { let session: String }
        return try await call("pair_start", Args(phone: phone), as: Result.self).session
    }

    public func cancelPairing(session: String) async throws {
        _ = try await call("pair_cancel", ["session": session], as: Ignored.self)
    }

    /// Unlinks an account: removed from the phone's Linked Devices and its keys deleted.
    /// Returns false when the phone could not be told (offline) — the keys are deleted
    /// either way, but the phone keeps listing the device until the user removes it.
    @discardableResult
    public func logout(account: String) async throws -> Bool {
        struct Result: Decodable { let unlinkedOnPhone: Bool }
        return try await call("logout", ["account": account], as: Result.self).unlinkedOnPhone
    }

    public func reconnect(account: String) async throws {
        _ = try await call("reconnect", ["account": account], as: Ignored.self)
    }

    // MARK: - Sending

    /// Sends text. `to` is a JID or a phone number in international format; a number is
    /// checked against WhatsApp first and refused if it isn't registered. Names are never
    /// accepted — there is no lookup that could pick the wrong person.
    public func sendText(account: String, to: String, text: String,
                         replyTo: WhatsMeowReplyReference? = nil) async throws -> WhatsMeowSendResult {
        struct Args: Encodable { let account, to, text: String; let replyTo: WhatsMeowReplyReference? }
        return try await call("send_text", Args(account: account, to: to, text: text, replyTo: replyTo))
    }

    /// Uploads a file and sends it. The service reads `file.path` itself.
    public func sendFile(account: String, to: String, file: WhatsMeowOutgoingFile) async throws -> WhatsMeowSendResult {
        struct Args: Encodable {
            let account, to: String
            let file: WhatsMeowOutgoingFile
            func encode(to encoder: any Encoder) throws {
                // The library takes the file's fields flat, beside account and to.
                try file.encode(to: encoder)
                var container = encoder.container(keyedBy: Keys.self)
                try container.encode(account, forKey: .account)
                try container.encode(to, forKey: .to)
            }
            enum Keys: String, CodingKey { case account, to }
        }
        return try await call("send_media", Args(account: account, to: to, file: file))
    }

    /// Reacts to `message` with an emoji, or removes the reaction with "".
    public func react(account: String, to message: WhatsMeowMessage, emoji: String) async throws -> WhatsMeowSendResult {
        struct Args: Encodable { let account, chat, sender, id, emoji: String; let fromMe: Bool }
        return try await call("react", Args(account: account, chat: message.wireChat, sender: message.wireSender,
                                            id: message.id, emoji: emoji, fromMe: message.fromMe))
    }

    /// Sends read receipts. All messages must belong to `chat`, given as WhatsApp
    /// addressed it (`wireChat`).
    public func markRead(account: String, chat: String, messages: [WhatsMeowMessage]) async throws {
        struct Item: Encodable { let id, sender: String }
        struct Args: Encodable { let account, chat: String; let messages: [Item] }
        _ = try await call("mark_read", Args(account: account, chat: chat,
                                             messages: messages.map { Item(id: $0.id, sender: $0.wireSender) }),
                           as: Ignored.self)
    }

    // MARK: - Reading

    /// Decrypts an attachment to `path` and returns its size in bytes. The bytes never
    /// cross XPC. `media` is `WhatsMeowMessage.Media.raw`.
    @discardableResult
    public func download(account: String, media: Data, to path: String) async throws -> Int {
        struct Args: Encodable { let account: String; let raw: Data; let path: String }
        struct Result: Decodable { let size: Int }
        return try await call("download", Args(account: account, raw: media, path: path), as: Result.self).size
    }

    public func contacts(account: String) async throws -> [WhatsMeowContact] {
        try await call("contacts", ["account": account])
    }

    /// Every group the account is in, without participants.
    public func groups(account: String) async throws -> [WhatsMeowGroup] {
        try await call("groups", ["account": account])
    }

    /// One group, with participants, fresh from WhatsApp.
    public func groupInfo(account: String, jid: String) async throws -> WhatsMeowGroup {
        try await call("group_info", ["account": account, "jid": jid])
    }

    /// Which of these phone numbers are on WhatsApp, and their JIDs.
    public func resolve(account: String, phones: [String]) async throws -> [WhatsMeowLookup] {
        struct Args: Encodable { let account: String; let phones: [String] }
        return try await call("resolve", Args(account: account, phones: phones))
    }

    /// The phone numbers whatsmeow knows these LIDs stand for — only the known ones come
    /// back. Read from its store; nothing is sent to WhatsApp.
    public func phonesForLIDs(account: String, lids: [String]) async throws -> [WhatsMeowLIDMapping] {
        struct Args: Encodable { let account: String; let lids: [String] }
        return try await call("phones_for_lids", Args(account: account, lids: lids))
    }

    // MARK: - XPC

    private func sendStart(_ options: WhatsMeowStartOptions) async throws -> Data {
        let encoded = try JSONEncoder().encode(options)
        return try await send { proxy, reply in
            proxy.start(options: encoded, reply: reply)
        }
    }

    private func send(_ body: @escaping (WhatsMeowServiceProtocol, @escaping @Sendable (Data) -> Void) -> Void) async throws -> Data {
        let connection = currentConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.run {
                    continuation.resume(throwing: WhatsMeowError(
                        code: WhatsMeowError.serviceUnavailableCode,
                        message: "The WhatsApp service is unavailable: \(error.localizedDescription)"))
                }
            } as? WhatsMeowServiceProtocol
            guard let proxy else {
                once.run {
                    continuation.resume(throwing: WhatsMeowError(
                        code: WhatsMeowError.serviceUnavailableCode, message: "The WhatsApp service has the wrong interface."))
                }
                return
            }
            body(proxy) { data in once.run { continuation.resume(returning: data) } }
        }
    }

    private func currentConnection() -> NSXPCConnection {
        lock.withLock {
            if let connection { return connection }
            let connection = makeConnection()
            connection.remoteObjectInterface = WhatsMeowXPC.serviceInterface()
            connection.exportedInterface = WhatsMeowXPC.eventInterface()
            connection.exportedObject = receiver
            connection.interruptionHandler = { [weak self] in self?.serviceInterrupted() }
            connection.invalidationHandler = { [weak self] in self?.connectionInvalidated(connection) }
            connection.resume()
            self.connection = connection
            return connection
        }
    }

    /// The service process exited (crash, or the system reclaimed it). The connection
    /// object stays usable and the next message relaunches the service — so relaunch it,
    /// with the same options, to bring the accounts back.
    private func serviceInterrupted() {
        let (options, attempt) = lock.withLock { () -> (WhatsMeowStartOptions?, Int) in
            restartAttempt += 1
            return (self.options, restartAttempt)
        }
        guard let options else { return }
        Task {
            // 0.5 s, 1 s, 2 s … capped at 30 s: a service that crashes on launch must not
            // become a busy loop.
            let delay = min(30, 0.5 * pow(2, Double(attempt - 1)))
            try? await Task.sleep(for: .seconds(delay))
            do {
                _ = try WhatsMeowEnvelope.result(try await sendStart(options))
                lock.withLock { restartAttempt = 0 }
                deliver(.serviceRestarted)
            } catch {
                deliver(.log(level: "error", module: "XPCWhatsMeow",
                             message: "Could not restart the WhatsApp service: \(error.localizedDescription)"))
            }
        }
    }

    private func connectionInvalidated(_ invalidated: NSXPCConnection) {
        lock.withLock {
            if connection === invalidated { connection = nil }
        }
    }

    fileprivate func deliver(_ event: WhatsMeowEvent) {
        let handler = lock.withLock { onEvent }
        handler?(event)
    }

    fileprivate func deliver(json: Data) {
        let event: WhatsMeowEvent
        do {
            event = try WhatsMeowEvent(json: json)
        } catch {
            event = .log(level: "error", module: "XPCWhatsMeow",
                         message: "Undecodable event (\(json.count) bytes): \(error.localizedDescription)")
        }
        deliver(event)
    }
}

/// What the app exports for the service to call.
private final class EventReceiver: NSObject, WhatsMeowEventReceiving, @unchecked Sendable {
    weak var client: WhatsMeowClient?

    func receive(event: Data) {
        client?.deliver(json: event)
    }
}

/// Guards a continuation against the reply and the error handler both firing.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}

private struct Empty: Encodable {}
private struct Ignored: Decodable {
    init(from decoder: any Decoder) throws {}
}
