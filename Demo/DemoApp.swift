import CoreImage.CIFilterBuiltins
import SwiftUI
import XPCWhatsMeow

/// A minimal app on top of the service: link an account by QR code, watch accounts and
/// messages arrive. It is also the quickest end-to-end check that the .xpc is embedded,
/// signed and reachable.
@main
struct WhatsMeowDemoApp: App {
    @State private var model = DemoModel()

    init() {
        let arguments = CommandLine.arguments
        guard arguments.contains("--check") else { return }
        Task {
            exit(await EndToEndCheck.run(offline: arguments.contains("--offline")))
        }
        // Keep the run loop going for the check without ever showing a window.
        dispatchMain()
    }

    var body: some Scene {
        WindowGroup("WhatsMeow Demo") {
            DemoView(model: model)
                .task { await model.start() }
        }
        .defaultSize(width: 720, height: 520)
    }
}

@MainActor
@Observable
final class DemoModel {
    let client = WhatsMeowClient()
    var accounts: [WhatsMeowAccount] = []
    var qrCode: String?
    var pairingSession: String?
    var status = "Starting…"
    var log: [String] = []

    func start() async {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhatsMeowDemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        do {
            try await client.start(WhatsMeowStartOptions(
                databasePath: support.appendingPathComponent("session.db").path,
                deviceName: "WhatsMeow Demo", fullHistory: false
            )) { event in
                Task { @MainActor in self.handle(event) }
            }
            status = "Service running"
            await refresh()
        } catch {
            status = "Could not start the service: \(error.localizedDescription)"
        }
    }

    func refresh() async {
        accounts = (try? await client.accounts()) ?? []
    }

    func link() async {
        do {
            pairingSession = try await client.startPairing()
            status = "Waiting for a QR code…"
        } catch {
            status = error.localizedDescription
        }
    }

    func unlink(_ account: WhatsMeowAccount) async {
        _ = try? await client.logout(account: account.account)
        await refresh()
    }

    private func handle(_ event: WhatsMeowEvent) {
        switch event {
        case .pairQR(let session, let code) where session == pairingSession:
            qrCode = code
            status = "Scan with WhatsApp › Linked Devices › Link a Device"
        case .pairSuccess(_, let account, let name):
            qrCode = nil; pairingSession = nil
            status = "Linked \(name ?? account)"
            Task { await refresh() }
        case .pairFailed(_, _, let message):
            qrCode = nil; pairingSession = nil
            status = message
        case .accountState(let account, let state, _):
            append("\(account): \(state)")
            Task { await refresh() }
        case .messages(let account, let source, let messages):
            for message in messages.suffix(20) {
                let who = message.fromMe ? "me" : (message.pushName ?? message.sender)
                append("[\(source)] \(account) \(who): \(message.text ?? "[\(message.kind)]")")
            }
        case .serviceRestarted:
            append("service restarted")
        default:
            break
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}

struct DemoView: View {
    let model: DemoModel

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Accounts").font(.headline)
                ForEach(model.accounts, id: \.account) { account in
                    HStack {
                        Circle().fill(account.connected ? .green : .orange).frame(width: 8, height: 8)
                        Text(account.pushName ?? account.account)
                        Spacer()
                        Button("Unlink") { Task { await model.unlink(account) } }
                    }
                }
                Button("Link an Account") { Task { await model.link() } }
                if let code = model.qrCode, let image = qrImage(code) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220)
                        .padding(8).background(.white)
                }
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .frame(minWidth: 260)

            List(Array(model.log.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(.caption, design: .monospaced))
            }
        }
    }

    private func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
