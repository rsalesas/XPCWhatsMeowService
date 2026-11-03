import Foundation
import XPCWhatsMeow

/// `WhatsMeowDemo --check`: drives the embedded service through launchd, headless, and
/// exits 0 if every step works. It needs the real bundle — this is what proves the .xpc is
/// embedded, signed, launchable and wired up, which no in-process test can.
///
///   1. start the service on a throwaway session database
///   2. list accounts (empty)
///   3. a bad call comes back as a typed error
///   4. pairing produces a QR code from WhatsApp's servers   (skipped with --offline)
///   5. stop
enum EndToEndCheck {
    static func run(offline: Bool) async -> Int32 {
        func step(_ name: String, _ body: () async throws -> Void) async -> Bool {
            do {
                try await body()
                print("✓ \(name)")
                return true
            } catch {
                print("✗ \(name): \(error.localizedDescription)")
                return false
            }
        }

        let client = WhatsMeowClient()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WhatsMeowDemo check \(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let codes = QRCodes()

        var ok = await step("service starts") {
            try await client.start(WhatsMeowStartOptions(databasePath: dir.appendingPathComponent("session.db").path,
                                                         deviceName: "WhatsMeow Demo check")) { event in
                if case .pairQR(_, let code) = event { codes.received(code) }
            }
        }
        guard ok else { return 1 }

        ok = await step("accounts are listed") {
            let accounts = try await client.accounts()
            guard accounts.isEmpty else { throw CheckFailure("expected no accounts, got \(accounts.count)") }
        } && ok

        ok = await step("errors come back typed") {
            do {
                _ = try await client.sendText(account: "1555", to: "x", text: "hi")
                throw CheckFailure("the call succeeded")
            } catch let error as WhatsMeowError where error.code == "unknown_account" {}
        } && ok

        if !offline {
            ok = await step("pairing yields a QR code") {
                let session = try await client.startPairing()
                for _ in 0..<60 where codes.first == nil {
                    try await Task.sleep(for: .milliseconds(250))
                }
                try? await client.cancelPairing(session: session)
                guard codes.first != nil else { throw CheckFailure("no QR code within 15 seconds") }
            } && ok
        }

        await client.stop()
        print(ok ? "All checks passed." : "Some checks failed.")
        return ok ? 0 : 1
    }
}

private struct CheckFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private final class QRCodes: @unchecked Sendable {
    private let lock = NSLock()
    private var code: String?
    var first: String? { lock.withLock { code } }
    func received(_ value: String) { lock.withLock { if code == nil { code = value } } }
}
