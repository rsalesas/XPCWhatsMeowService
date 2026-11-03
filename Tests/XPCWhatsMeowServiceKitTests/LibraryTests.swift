import Foundation
import Testing
import XPCWhatsMeow
import XPCWhatsMeowProtocol
@testable import XPCWhatsMeowServiceKit

/// The Go library is process-global, so everything that touches it is in this one
/// serialized suite.
@Suite("Go library", .serialized)
struct LibraryTests {
    private static func options(_ extra: [String: Any] = [:]) -> (Data, String) {
        // A space in the path: Application Support has one, and the library builds a
        // SQLite URI from it.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wa lib \(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("session.db").path
        var object: [String: Any] = ["databasePath": path, "deviceName": "XPCWhatsMeowService tests"]
        object.merge(extra) { _, new in new }
        return (try! JSONSerialization.data(withJSONObject: object), path)
    }

    private static func string(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test func inProcessStartCallStop() throws {
        let library = WhatsMeowLibrary.shared
        let (options, path) = Self.options()
        #expect(Self.string(library.start(options: options, events: { _ in })) == #"{"result":{"accounts":[]}}"#)
        defer { library.stop() }
        #expect(library.isRunning)
        #expect(FileManager.default.fileExists(atPath: path))

        #expect(Self.string(library.call("accounts", arguments: Data("{}".utf8))) == #"{"result":[]}"#)
        #expect(Self.string(library.call("nope", arguments: Data("{}".utf8)))
                == #"{"error":{"code":"unknown_method","message":"unknown bridge method \"nope\""}}"#)
        #expect(Self.string(library.call("send_text", arguments: Data(#"{"account":"1555","to":"x","text":"hi"}"#.utf8)))
                .contains(#""code":"unknown_account""#))
        #expect(Self.string(library.call("accounts", arguments: Data("not json".utf8))).contains("error") == false)
        #expect(Self.string(library.call("send_text", arguments: Data("not json".utf8))).contains(#""code":"invalid_argument""#))
    }

    @Test func refusesBadOptionsAndRestarts() throws {
        let library = WhatsMeowLibrary.shared
        #expect(Self.string(library.start(options: Data("{}".utf8), events: { _ in })).contains("databasePath is required"))
        #expect(!library.isRunning)

        _ = library.start(options: Self.options().0, events: { _ in })
        // Starting again while running hands events to the new caller instead of failing.
        #expect(Self.string(library.start(options: Self.options().0, events: { _ in })).contains(#""alreadyRunning":true"#))
        library.stop()
        #expect(!library.isRunning)
        #expect(Self.string(library.call("accounts", arguments: Data("{}".utf8))).contains("not_started"))

        _ = library.start(options: Self.options().0, events: { _ in })
        defer { library.stop() }
        #expect(Self.string(library.call("accounts", arguments: Data("{}".utf8))) == #"{"result":[]}"#)
    }

    /// The whole stack, client to Go, over a real XPC connection (an anonymous listener in
    /// this process — the same code path as the service, minus launchd).
    @Test func clientThroughRealServiceOverXPC() async throws {
        let delegate = WhatsMeowServiceListener(clientRequirement: nil)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let client = WhatsMeowClient(endpoint: listener.endpoint)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wa xpc \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await client.start(WhatsMeowStartOptions(databasePath: dir.appendingPathComponent("s.db").path)) { _ in }

        #expect(try await client.accounts().isEmpty)
        await #expect(throws: WhatsMeowError(code: "unknown_account", message: "no linked WhatsApp account 1555")) {
            _ = try await client.sendText(account: "1555", to: "x", text: "hi")
        }
        await client.stop()
        #expect(!WhatsMeowLibrary.shared.isRunning)
    }

    /// Dials WhatsApp's servers for a real pairing QR code, through XPC.
    /// Opt-in: XPCWHATSMEOW_LIVE=1 swift test
    @Test(.enabled(if: ProcessInfo.processInfo.environment["XPCWHATSMEOW_LIVE"] == "1"))
    func liveQRCodeOverXPC() async throws {
        let delegate = WhatsMeowServiceListener(clientRequirement: nil)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let codes = CodeBox()
        let client = WhatsMeowClient(endpoint: listener.endpoint)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wa live \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await client.start(WhatsMeowStartOptions(databasePath: dir.appendingPathComponent("s.db").path)) { event in
            if case .pairQR(_, let code) = event { codes.set(code) }
        }
        let session = try await client.startPairing()
        for _ in 0..<40 where codes.value == nil {
            try await Task.sleep(for: .milliseconds(250))
        }
        try await client.cancelPairing(session: session)
        await client.stop()
        #expect(codes.value?.isEmpty == false)
    }
}

private final class CodeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? { lock.withLock { _value } }
    func set(_ v: String) { lock.withLock { if _value == nil { _value = v } } }
}
