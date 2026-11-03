import Foundation

/// Something that happened, pushed by the service.
public enum WhatsMeowEvent: Sendable, Equatable {
    /// connected, disconnected (it reconnects by itself), logged_out (the keys are gone —
    /// forget the account), stream_replaced (another connection took over this link),
    /// temporarily_banned, connect_failure, client_outdated.
    case accountState(account: String, state: String, detail: String?)
    /// A QR code to show; replaced every 20 seconds or so until pairing ends.
    case pairQR(session: String, code: String)
    /// A code for the user to type on the phone (phone-number pairing).
    case pairCode(session: String, code: String)
    case pairSuccess(session: String, account: String, pushName: String?)
    /// Pairing is over. Exactly one of this or `pairSuccess` ends a session.
    case pairFailed(session: String, reason: String, message: String)
    /// `source` is live, history (from the phone's history sync) or sent (by this client).
    case messages(account: String, source: String, messages: [WhatsMeowMessage])
    /// Chat names and flags. From history sync these carry unread counts; they arrive after
    /// the messages they count.
    case chats(account: String, chats: [WhatsMeowChat])
    /// Delivery or read receipts. From others (`fromMe == false`) they advance the status of
    /// the user's messages: "" delivered, "read", "played". With `fromMe`, another of the
    /// user's devices read incoming messages ("read-self", "played-self").
    case receipt(account: String, chat: String, ids: [String], receiptType: String, fromMe: Bool)
    /// Names in the contact store changed; re-read `contacts` if you cache them.
    case contactsChanged(account: String)
    /// History sync progress, 0–100.
    case historyProgress(account: String, syncType: String, progress: Int)
    /// A line from whatsmeow's own log: error, warning or info.
    case log(level: String, module: String, message: String)
    /// The service process died and was restarted. Accounts are reconnecting; a pairing in
    /// progress was lost.
    case serviceRestarted
    /// A newer service sent something this client doesn't know.
    case unknown(String)

    /// Decodes one event as the service sends it.
    public init(json data: Data) throws {
        let decoder = JSONDecoder()
        let head = try decoder.decode(Head.self, from: data)
        switch head.type {
        case "account_state":
            let e = try decoder.decode(AccountState.self, from: data)
            self = .accountState(account: e.account, state: e.state, detail: e.detail.flatMap { $0.isEmpty ? nil : $0 })
        case "pair_qr":
            let e = try decoder.decode(Pair.self, from: data)
            self = .pairQR(session: e.session, code: e.code ?? "")
        case "pair_code":
            let e = try decoder.decode(Pair.self, from: data)
            self = .pairCode(session: e.session, code: e.code ?? "")
        case "pair_success":
            let e = try decoder.decode(Pair.self, from: data)
            self = .pairSuccess(session: e.session, account: e.account ?? "", pushName: e.pushName.flatMap { $0.isEmpty ? nil : $0 })
        case "pair_failed":
            let e = try decoder.decode(Pair.self, from: data)
            self = .pairFailed(session: e.session, reason: e.reason ?? "error", message: e.message ?? "Pairing failed")
        case "messages":
            let e = try decoder.decode(Messages.self, from: data)
            self = .messages(account: e.account, source: e.source, messages: e.messages)
        case "chats":
            let e = try decoder.decode(Chats.self, from: data)
            self = .chats(account: e.account, chats: e.chats)
        case "receipt":
            let e = try decoder.decode(Receipt.self, from: data)
            self = .receipt(account: e.account, chat: e.chat, ids: e.ids ?? [], receiptType: e.receiptType, fromMe: e.fromMe)
        case "contacts_changed":
            self = .contactsChanged(account: try decoder.decode(AccountOnly.self, from: data).account)
        case "history_progress":
            let e = try decoder.decode(HistoryProgress.self, from: data)
            self = .historyProgress(account: e.account, syncType: e.syncType, progress: e.progress ?? 0)
        case "log":
            let e = try decoder.decode(Log.self, from: data)
            self = .log(level: e.level, module: e.module, message: e.message)
        default:
            self = .unknown(head.type)
        }
    }

    private struct Head: Decodable { let type: String }
    private struct AccountState: Decodable { let account: String; let state: String; let detail: String? }
    private struct Pair: Decodable {
        let session: String
        let code: String?
        let account: String?
        let pushName: String?
        let reason: String?
        let message: String?
    }
    private struct Messages: Decodable { let account: String; let source: String; let messages: [WhatsMeowMessage] }
    private struct Chats: Decodable { let account: String; let chats: [WhatsMeowChat] }
    private struct Receipt: Decodable {
        let account: String
        let chat: String
        let ids: [String]?
        let receiptType: String
        let fromMe: Bool
    }
    private struct AccountOnly: Decodable { let account: String }
    private struct HistoryProgress: Decodable { let account: String; let syncType: String; let progress: Int? }
    private struct Log: Decodable { let level: String; let module: String; let message: String }
}

/// A failure reported by the library or the service, with a stable code to switch on.
public struct WhatsMeowError: Error, LocalizedError, Sendable, Equatable {
    /// e.g. not_connected, unknown_account, invalid_recipient, not_on_whatsapp,
    /// send_failed, media_expired — or service_unavailable when the XPC service is missing
    /// or died mid-call.
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    public static let serviceUnavailableCode = "service_unavailable"
}

/// The `{"result": …}` / `{"error": …}` envelope every reply comes in.
public enum WhatsMeowEnvelope {
    /// The JSON of `result`, or the error the envelope carries.
    public static func result(_ envelope: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: envelope) as? [String: Any] else {
            throw WhatsMeowError(code: "decoding", message: "The WhatsApp service sent an unreadable reply.")
        }
        if let failure = object["error"] as? [String: Any] {
            throw WhatsMeowError(code: failure["code"] as? String ?? "failed",
                                 message: failure["message"] as? String ?? "The WhatsApp service reported an error.")
        }
        guard let result = object["result"] else { return Data("null".utf8) }
        return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
    }
}
