import Foundation

/// The XPC contract between an app (through `XPCWhatsMeow`) and the service.
///
/// Deliberately thin. Every operation is one `call`, its arguments and its reply are JSON,
/// and events travel back as JSON too — the same shapes the Go library speaks across its C
/// ABI. The service forwards bytes in both directions without decoding them, so adding an
/// operation never changes this interface, and the service never needs updating in step
/// with an app's understanding of a payload.
public enum WhatsMeowXPC {
    /// The service's bundle identifier when built from this repository's project. An app
    /// that rebrands the service passes its own to `WhatsMeowClient(serviceName:)`.
    public static let defaultServiceName = "com.siliconink.XPCWhatsMeowService"

    /// What the service exports.
    public static func serviceInterface() -> NSXPCInterface {
        NSXPCInterface(with: WhatsMeowServiceProtocol.self)
    }

    /// What the app exports, so the service can push events to it.
    public static func eventInterface() -> NSXPCInterface {
        NSXPCInterface(with: WhatsMeowEventReceiving.self)
    }
}

/// Implemented by the service.
@objc public protocol WhatsMeowServiceProtocol {
    /// Opens the session database and connects every linked device. `options` is the JSON
    /// object `WA_Start` takes. The reply is the library's JSON envelope:
    /// `{"result": …}` or `{"error": {"code": …, "message": …}}`.
    ///
    /// Events are sent to the calling connection's exported `WhatsMeowEventReceiving`.
    /// Starting an already running service re-targets events at the caller and succeeds.
    func start(options: Data, reply: @escaping @Sendable (Data) -> Void)

    /// Runs one operation. `arguments` is a JSON object; the reply is an envelope.
    func call(method: String, arguments: Data, reply: @escaping @Sendable (Data) -> Void)

    /// Disconnects every account. The service may exit afterwards.
    func stop(reply: @escaping @Sendable () -> Void)
}

/// Implemented by the app.
@objc public protocol WhatsMeowEventReceiving {
    /// One event as a JSON object. Delivered one at a time, in the order they happened.
    func receive(event: Data)
}
