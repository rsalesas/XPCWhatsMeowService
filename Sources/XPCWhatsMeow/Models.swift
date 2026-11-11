import Foundation

// The shapes the service speaks, field for field (Go/wabridge). Accounts are phone
// numbers as bare digits — "15551234567" — because that is the user part of the device's
// JID; chats and senders are JIDs ("15551234567@s.whatsapp.net", "1203…@g.us", "…@lid").

/// A linked WhatsApp account: one of the phone's companion-device slots.
public struct WhatsMeowAccount: Codable, Sendable, Equatable {
    public var account: String
    public var jid: String?
    public var lid: String?
    public var pushName: String?
    public var businessName: String?
    public var platform: String?
    public var connected: Bool
    public var loggedIn: Bool

    public init(account: String, jid: String? = nil, lid: String? = nil, pushName: String? = nil,
                businessName: String? = nil, platform: String? = nil, connected: Bool, loggedIn: Bool) {
        self.account = account; self.jid = jid; self.lid = lid; self.pushName = pushName
        self.businessName = businessName; self.platform = platform
        self.connected = connected; self.loggedIn = loggedIn
    }
}

/// One message, normalised from whatever WhatsApp wrapped it in.
///
/// `kind` is text, image, video, gif, audio, voice, document, sticker, location, contact or
/// poll — or one of three that *modify* another message instead of standing alone:
/// `reaction` (text is the emoji, empty to remove), `edit` (text is the new content) and
/// `revoke` (deleted for everyone). Those name their target in `targetId`.
public struct WhatsMeowMessage: Codable, Sendable, Equatable {
    public var id: String
    /// Phone-number JID where the LID mapping is known, else as received.
    public var chat: String
    public var sender: String
    /// The chat/sender exactly as WhatsApp addressed them, when that differs (a LID).
    /// Receipts and reactions must be sent to these.
    public var rawChat: String?
    public var rawSender: String?
    public var pushName: String?
    public var fromMe: Bool
    public var isGroup: Bool
    /// Unix seconds.
    public var timestamp: Int64
    public var kind: String
    public var text: String?
    public var quotedId: String?
    public var targetId: String?
    public var media: Media?

    public struct Media: Codable, Sendable, Equatable {
        public var mimeType: String?
        public var fileName: String?
        public var fileSize: Int?
        public var seconds: Int?
        public var width: Int?
        public var height: Int?
        /// Opaque: the encrypted media's reference and key. Keep it to download later with
        /// `WhatsMeowClient.download(account:media:to:)`; treat it as a secret.
        public var raw: Data

        public init(mimeType: String? = nil, fileName: String? = nil, fileSize: Int? = nil, seconds: Int? = nil,
                    width: Int? = nil, height: Int? = nil, raw: Data) {
            self.mimeType = mimeType; self.fileName = fileName; self.fileSize = fileSize
            self.seconds = seconds; self.width = width; self.height = height; self.raw = raw
        }
    }

    public init(id: String, chat: String, sender: String, rawChat: String? = nil, rawSender: String? = nil,
                pushName: String? = nil, fromMe: Bool, isGroup: Bool, timestamp: Int64, kind: String,
                text: String? = nil, quotedId: String? = nil, targetId: String? = nil, media: Media? = nil) {
        self.id = id; self.chat = chat; self.sender = sender; self.rawChat = rawChat; self.rawSender = rawSender
        self.pushName = pushName; self.fromMe = fromMe; self.isGroup = isGroup; self.timestamp = timestamp
        self.kind = kind; self.text = text; self.quotedId = quotedId; self.targetId = targetId; self.media = media
    }

    /// Where receipts and reactions for this message go.
    public var wireChat: String { rawChat ?? chat }
    public var wireSender: String { rawSender ?? sender }
}

/// What the service knows about a chat: from history sync, group events and group lists.
public struct WhatsMeowChat: Codable, Sendable, Equatable {
    public var jid: String
    public var name: String?
    public var isGroup: Bool
    /// From history sync only: how many messages were unread on the phone.
    public var unreadCount: Int?
    public var archived: Bool?

    public init(jid: String, name: String? = nil, isGroup: Bool, unreadCount: Int? = nil, archived: Bool? = nil) {
        self.jid = jid; self.name = name; self.isGroup = isGroup; self.unreadCount = unreadCount; self.archived = archived
    }
}

/// An entry in the account's contact store: address-book names synced from the phone, plus
/// the push names people chose for themselves.
public struct WhatsMeowContact: Codable, Sendable, Equatable {
    public var jid: String
    public var phone: String?
    public var firstName: String?
    public var fullName: String?
    public var pushName: String?
    public var businessName: String?

    public init(jid: String, phone: String? = nil, firstName: String? = nil, fullName: String? = nil,
                pushName: String? = nil, businessName: String? = nil) {
        self.jid = jid; self.phone = phone; self.firstName = firstName; self.fullName = fullName
        self.pushName = pushName; self.businessName = businessName
    }
}

public struct WhatsMeowGroup: Codable, Sendable, Equatable {
    public var jid: String
    public var name: String
    public var topic: String?
    /// Unix seconds.
    public var created: Int64?
    public var owner: String?
    public var isAnnounce: Bool
    public var isLocked: Bool
    public var participantCount: Int
    /// Only from `groupInfo`; `groups` leaves it out.
    public var participants: [Participant]?

    public struct Participant: Codable, Sendable, Equatable {
        public var jid: String
        public var phone: String?
        public var lid: String?
        public var isAdmin: Bool
        public var isSuperAdmin: Bool
        public var displayName: String?
    }
}

public struct WhatsMeowSendResult: Codable, Sendable, Equatable {
    public var account: String
    public var chat: String
    public var id: String
    /// Unix seconds, as WhatsApp's server stamped it.
    public var timestamp: Int64
    /// The sent message, normalised like an incoming one. It is also delivered as a
    /// `messages` event with source `sent` — whatsmeow never echoes a client's own sends.
    public var message: WhatsMeowMessage?
}

/// The message a reply quotes.
public struct WhatsMeowReplyReference: Codable, Sendable, Equatable {
    public var id: String
    /// The quoted message's sender as received (`WhatsMeowMessage.wireSender`).
    public var sender: String
    /// Shown above the reply on the recipient's side.
    public var text: String

    public init(id: String, sender: String, text: String) {
        self.id = id; self.sender = sender; self.text = text
    }

    public init(quoting message: WhatsMeowMessage) {
        self.init(id: message.id, sender: message.wireSender, text: message.text ?? "")
    }
}

/// A file to send. The service reads it from disk itself — bytes never cross XPC.
public struct WhatsMeowOutgoingFile: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Recipients see it inline. WhatsApp clients reliably render JPEG and PNG.
        case image
        /// MP4 (H.264) plays everywhere.
        case video
        case audio
        /// An audio file shown as a voice note (Opus in OGG, by convention).
        case voice
        /// Anything, delivered as a file.
        case document
    }

    public var path: String
    public var kind: Kind
    public var mimeType: String
    public var fileName: String?
    /// Not allowed for audio and voice — WhatsApp has nowhere to show it.
    public var caption: String?
    public var seconds: Int?
    public var width: Int?
    public var height: Int?
    /// A small JPEG shown before the file downloads.
    public var thumbnail: Data?
    public var replyTo: WhatsMeowReplyReference?

    public init(path: String, kind: Kind, mimeType: String, fileName: String? = nil, caption: String? = nil,
                seconds: Int? = nil, width: Int? = nil, height: Int? = nil, thumbnail: Data? = nil,
                replyTo: WhatsMeowReplyReference? = nil) {
        self.path = path; self.kind = kind; self.mimeType = mimeType; self.fileName = fileName
        self.caption = caption; self.seconds = seconds; self.width = width; self.height = height
        self.thumbnail = thumbnail; self.replyTo = replyTo
    }
}

/// One answer from `resolve`.
public struct WhatsMeowLookup: Codable, Sendable, Equatable {
    public var query: String
    public var jid: String
    public var isOnWhatsApp: Bool
}

/// A LID and the phone-number JID whatsmeow knows it stands for.
public struct WhatsMeowLIDMapping: Codable, Sendable, Equatable {
    public let lid: String
    public let phone: String

    public init(lid: String, phone: String) {
        self.lid = lid
        self.phone = phone
    }
}

/// How `start` configures the library.
public struct WhatsMeowStartOptions: Codable, Sendable, Equatable {
    /// whatsmeow's session database: every linked device's keys. Treat it as a credential.
    public var databasePath: String
    /// What the phone lists under Linked Devices.
    public var deviceName: String?
    /// Ask the phone for a full history sync when linking, rather than only recent chats.
    public var fullHistory: Bool
    /// With `fullHistory`, how many days back.
    public var historyDays: Int?

    public init(databasePath: String, deviceName: String? = nil, fullHistory: Bool = true, historyDays: Int? = nil) {
        self.databasePath = databasePath; self.deviceName = deviceName
        self.fullHistory = fullHistory; self.historyDays = historyDays
    }
}
