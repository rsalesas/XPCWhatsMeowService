import CWhatsMeow
import Foundation

/// The Go library, in process: Swift over the four functions of `wabridge.h`.
///
/// Used by the XPC service, and by this package's tests. An app should not link this
/// module — that would put whatsmeow, and its GPLv3 dependency, into the app's own binary.
/// Apps use `XPCWhatsMeow`, which reaches this through the service.
///
/// The Go side is process-global (one `WA_Start` per process), hence one shared instance.
/// Every method returns or forwards the library's raw JSON envelope; decoding is the
/// client's business.
public final class WhatsMeowLibrary: @unchecked Sendable {
    public static let shared = WhatsMeowLibrary()

    private let lock = NSLock()
    private var sink: EventSink?

    private init() {}

    /// Whether `start` has succeeded and `stop` has not been called since.
    public var isRunning: Bool { lock.withLock { sink != nil } }

    /// Starts the library. `events` receives every event's JSON, in order, on Go's threads.
    ///
    /// If it is already running, the new `events` handler replaces the old one and the
    /// reply is a success envelope with `"alreadyRunning": true` — the case of an app that
    /// reconnects to a service that outlived its previous connection.
    public func start(options: Data, events: @escaping @Sendable (Data) -> Void) -> Data {
        lock.withLock {
            if let sink {
                sink.replace(events)
                return Self.successEnvelope(["alreadyRunning": true])
            }
            let sink = EventSink(events)
            // Go keeps this pointer, unretained, until WA_Stop; this retain keeps the sink
            // alive meanwhile, and stop() balances it.
            let context = Unmanaged.passRetained(sink).toOpaque()
            let json = String(decoding: options, as: UTF8.self)
            let reply = Self.take(json.withCString { WA_Start($0, deliverEvent, context) })
            if Self.isSuccess(reply) {
                self.sink = sink
            } else {
                Unmanaged<EventSink>.fromOpaque(context).release()
            }
            return reply
        }
    }

    /// Runs one operation and returns its envelope. Blocks until it finishes — network
    /// operations can take a while, so call this off any thread that matters.
    public func call(_ method: String, arguments: Data) -> Data {
        let json = String(decoding: arguments, as: UTF8.self)
        return Self.take(method.withCString { m in json.withCString { WA_Call(m, $0) } })
    }

    /// Disconnects everything. No event is delivered after this returns.
    public func stop() {
        lock.withLock {
            guard let sink else { return }
            WA_Stop()
            // Safe only now: WA_Stop has returned, and Go delivers nothing after it does.
            Unmanaged.passUnretained(sink).release()
            self.sink = nil
        }
    }

    // MARK: - Envelopes

    /// Copies and frees a string the library returned.
    private static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> Data {
        guard let pointer else {
            return errorEnvelope(code: "no_reply", message: "The WhatsApp library returned nothing.")
        }
        defer { WA_Free(pointer) }
        return Data(bytes: pointer, count: strlen(pointer))
    }

    private static func isSuccess(_ envelope: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: envelope) as? [String: Any] else { return false }
        return object["error"] == nil
    }

    public static func errorEnvelope(code: String, message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": message]]))
            ?? Data(#"{"error":{"code":"encoding","message":"unencodable error"}}"#.utf8)
    }

    static func successEnvelope(_ result: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["result": result])) ?? Data(#"{"result":{}}"#.utf8)
    }
}

/// Owns the event handler for as long as Go may call it. Replaceable, so a reconnecting
/// client can take over a running library.
private final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: @Sendable (Data) -> Void

    init(_ handler: @escaping @Sendable (Data) -> Void) { self.handler = handler }

    func replace(_ handler: @escaping @Sendable (Data) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func deliver(_ data: Data) {
        let handler = lock.withLock { self.handler }
        handler(data)
    }
}

/// Called by Go, on Go's threads, once per event and in order. Copies the JSON out before
/// returning — Go frees it as soon as this does.
private let deliverEvent: wa_event_callback = { context, json in
    guard let context, let json else { return }
    let sink = Unmanaged<EventSink>.fromOpaque(context).takeUnretainedValue()
    sink.deliver(Data(bytes: json, count: strlen(json)))
}
