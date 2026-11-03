import Foundation
import Security
import XPC
import XPCWhatsMeowProtocol

/// The XPC service: accepts the app's connection and relays to `WhatsMeowLibrary`.
///
/// A service's `main.swift` is one line — `WhatsMeowServiceListener.runService()`.
public final class WhatsMeowServiceListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    /// A code-signing requirement every connecting client must meet, or nil to accept any
    /// client launchd lets through (tests use anonymous listeners, where that is the point).
    private let clientRequirement: String?

    public init(clientRequirement: String?) {
        self.clientRequirement = clientRequirement
    }

    /// Runs the service forever. Requires connecting apps to be signed by the same team as
    /// the service, when the service is signed by a team at all.
    public static func runService() -> Never {
        let delegate = WhatsMeowServiceListener(clientRequirement: sameTeamRequirement())
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
        // NSXPCListener.service() never returns from resume(); this satisfies the type.
        dispatchMain()
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let clientRequirement {
            // Checked by the system against the peer's audit token, per message — not a
            // PID lookup a reused PID could defeat.
            connection.setCodeSigningRequirement(clientRequirement)
        }
        connection.exportedInterface = WhatsMeowXPC.serviceInterface()
        connection.remoteObjectInterface = WhatsMeowXPC.eventInterface()
        let session = ServiceSession(connection: connection)
        connection.exportedObject = session
        connection.invalidationHandler = { session.connectionEnded() }
        connection.resume()
        return true
    }

    /// "Signed by my team", built from the service's own signature. Nil when the service
    /// has no team identifier (ad-hoc or unsigned development builds).
    static func sameTeamRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}

/// Which connection currently receives events, and whether the service has told the
/// system it is busy. Only that connection's departure stops the library: an app that
/// reconnects takes ownership, and its stale predecessor ending must not cut it off.
private enum Ownership {
    static let lock = NSLock()
    nonisolated(unsafe) static var owner: ObjectIdentifier?
    nonisolated(unsafe) static var transactionOpen = false
}

/// One app connection.
private final class ServiceSession: NSObject, WhatsMeowServiceProtocol, @unchecked Sendable {
    private weak var connection: NSXPCConnection?

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func start(options: Data, reply: @escaping @Sendable (Data) -> Void) {
        // XPC proxies are thread-safe; the type just doesn't say so.
        let receiver = Proxy(connection?.remoteObjectProxy as? WhatsMeowEventReceiving)
        let envelope = WhatsMeowLibrary.shared.start(options: options) { event in
            // Sends are asynchronous and keep their order on one connection.
            receiver.value?.receive(event: event)
        }
        if (try? JSONSerialization.jsonObject(with: envelope) as? [String: Any])?["error"] == nil {
            Ownership.lock.withLock {
                Ownership.owner = ObjectIdentifier(self)
                if !Ownership.transactionOpen {
                    Ownership.transactionOpen = true
                    // Linked accounts hold live connections; an idle XPC service would
                    // otherwise be fair game for the system to terminate.
                    xpc_transaction_begin()
                }
            }
        }
        reply(envelope)
    }

    func call(method: String, arguments: Data, reply: @escaping @Sendable (Data) -> Void) {
        // The library blocks on the network; never on XPC's own queue.
        DispatchQueue.global(qos: .userInitiated).async {
            reply(WhatsMeowLibrary.shared.call(method, arguments: arguments))
        }
    }

    func stop(reply: @escaping @Sendable () -> Void) {
        release()
        reply()
    }

    /// The app went away — quit, crashed, or invalidated the connection. Nobody is left to
    /// receive events, so disconnect rather than hold WhatsApp sessions open unattended.
    func connectionEnded() {
        release()
    }

    private func release() {
        let wasOwner = Ownership.lock.withLock {
            guard Ownership.owner == ObjectIdentifier(self) else { return false }
            Ownership.owner = nil
            return true
        }
        guard wasOwner else { return }
        WhatsMeowLibrary.shared.stop()
        Ownership.lock.withLock {
            if Ownership.transactionOpen {
                Ownership.transactionOpen = false
                xpc_transaction_end()
            }
        }
    }
}

private struct Proxy: @unchecked Sendable {
    let value: WhatsMeowEventReceiving?
    init(_ value: WhatsMeowEventReceiving?) { self.value = value }
}
