import Foundation
import Testing
@testable import XPCWhatsMeow
import XPCWhatsMeowProtocol

/// A stand-in service on an anonymous listener: records what it is asked, answers from a
/// table, and pushes events the way the real one does.
final class MockService: NSObject, WhatsMeowServiceProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    private let lock = NSLock()
    private var _calls: [(method: String, arguments: [String: Any])] = []
    private var events: WhatsMeowEventReceiving?
    var replies: [String: String] = [:]
    var eventsOnStart: [String] = []

    var calls: [(method: String, arguments: [String: Any])] { lock.withLock { _calls } }

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = WhatsMeowXPC.serviceInterface()
        connection.remoteObjectInterface = WhatsMeowXPC.eventInterface()
        connection.exportedObject = self
        connection.resume()
        lock.withLock { events = connection.remoteObjectProxy as? WhatsMeowEventReceiving }
        return true
    }

    private func record(_ method: String, _ data: Data) {
        let parsed = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        lock.withLock { _calls.append((method, parsed)) }
    }

    func start(options: Data, reply: @escaping @Sendable (Data) -> Void) {
        record("start", options)
        let receiver = lock.withLock { events }
        for event in eventsOnStart { receiver?.receive(event: Data(event.utf8)) }
        reply(Data((replies["start"] ?? #"{"result":{"accounts":[]}}"#).utf8))
    }

    func call(method: String, arguments: Data, reply: @escaping @Sendable (Data) -> Void) {
        record(method, arguments)
        reply(Data((replies[method] ?? #"{"result":{}}"#).utf8))
    }

    func stop(reply: @escaping @Sendable () -> Void) {
        record("stop", Data("{}".utf8))
        reply()
    }
}

/// Collects events in arrival order.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [WhatsMeowEvent] = []
    var events: [WhatsMeowEvent] { lock.withLock { _events } }
    func append(_ event: WhatsMeowEvent) { lock.withLock { _events.append(event) } }

    func waitFor(count: Int) async {
        for _ in 0..<200 where events.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Suite("Client over XPC")
struct ClientTests {
    @Test func startSendsOptionsAndDeliversEventsInOrder() async throws {
        let service = MockService()
        service.eventsOnStart = (1...20).map { #"{"type":"history_progress","account":"1","syncType":"FULL","progress":\#($0)}"# }
        let client = WhatsMeowClient(endpoint: service.listener.endpoint)
        let log = EventLog()

        try await client.start(WhatsMeowStartOptions(databasePath: "/tmp/x.db", deviceName: "Tests", historyDays: 30)) {
            log.append($0)
        }
        let options = try #require(service.calls.first { $0.method == "start" }?.arguments)
        #expect(options["databasePath"] as? String == "/tmp/x.db")
        #expect(options["deviceName"] as? String == "Tests")
        #expect(options["fullHistory"] as? Bool == true)
        #expect(options["historyDays"] as? Int == 30)

        await log.waitFor(count: 20)
        #expect(log.events == (1...20).map { .historyProgress(account: "1", syncType: "FULL", progress: $0) })
        await client.stop()
        #expect(service.calls.last?.method == "stop")
    }

    @Test func errorsArriveWithTheirCode() async throws {
        let service = MockService()
        service.replies["send_text"] = #"{"error":{"code":"not_on_whatsapp","message":"+1555 is not registered on WhatsApp"}}"#
        let client = WhatsMeowClient(endpoint: service.listener.endpoint)
        await #expect(throws: WhatsMeowError(code: "not_on_whatsapp", message: "+1555 is not registered on WhatsApp")) {
            _ = try await client.sendText(account: "1", to: "+1555", text: "hi")
        }
    }

    @Test func typedCallsDecodeReplies() async throws {
        let service = MockService()
        service.replies["accounts"] = #"{"result":[{"account":"15550100000","jid":"15550100000@s.whatsapp.net","pushName":"Robin","connected":true,"loggedIn":true}]}"#
        service.replies["pair_start"] = #"{"result":{"session":"S1"}}"#
        service.replies["download"] = #"{"result":{"path":"/tmp/a","size":12}}"#
        let client = WhatsMeowClient(endpoint: service.listener.endpoint)

        #expect(try await client.accounts() == [WhatsMeowAccount(account: "15550100000", jid: "15550100000@s.whatsapp.net",
                                                                  pushName: "Robin", connected: true, loggedIn: true)])
        #expect(try await client.startPairing(phone: "+1 555 010 0000") == "S1")
        #expect(service.calls.last?.arguments["phone"] as? String == "+1 555 010 0000")
        #expect(try await client.download(account: "1", media: Data([1, 2]), to: "/tmp/a") == 12)
        #expect(service.calls.last?.arguments["raw"] as? String == "AQI=")
    }

    /// The library takes a file's fields flat beside account and to.
    @Test func sendFileFlattensItsArguments() async throws {
        let service = MockService()
        service.replies["send_media"] = #"{"result":{"account":"1","chat":"2@s.whatsapp.net","id":"M","timestamp":5}}"#
        let client = WhatsMeowClient(endpoint: service.listener.endpoint)
        let file = WhatsMeowOutgoingFile(path: "/tmp/p.jpg", kind: .image, mimeType: "image/jpeg", caption: "hi",
                                         width: 10, height: 20, replyTo: WhatsMeowReplyReference(id: "Q", sender: "3@lid", text: "?"))
        let sent = try await client.sendFile(account: "1", to: "2@s.whatsapp.net", file: file)
        #expect(sent.id == "M")
        let args = try #require(service.calls.last?.arguments)
        #expect(args["account"] as? String == "1")
        #expect(args["to"] as? String == "2@s.whatsapp.net")
        #expect(args["path"] as? String == "/tmp/p.jpg")
        #expect(args["kind"] as? String == "image")
        #expect(args["width"] as? Int == 10)
        #expect((args["replyTo"] as? [String: Any])?["sender"] as? String == "3@lid")
    }

    /// Reactions and receipts go to the address WhatsApp used, not the normalised one.
    @Test func reactAndMarkReadUseWireAddresses() async throws {
        let service = MockService()
        let client = WhatsMeowClient(endpoint: service.listener.endpoint)
        let message = WhatsMeowMessage(id: "A", chat: "2@s.whatsapp.net", sender: "2@s.whatsapp.net",
                                       rawChat: "9@lid", rawSender: "9@lid", fromMe: false, isGroup: false,
                                       timestamp: 1, kind: "text", text: "hi")
        service.replies["react"] = #"{"result":{"account":"1","chat":"9@lid","id":"R","timestamp":2}}"#
        _ = try await client.react(account: "1", to: message, emoji: "👍")
        #expect(service.calls.last?.arguments["chat"] as? String == "9@lid")
        #expect(service.calls.last?.arguments["sender"] as? String == "9@lid")

        try await client.markRead(account: "1", chat: message.wireChat, messages: [message])
        let items = service.calls.last?.arguments["messages"] as? [[String: Any]]
        #expect(items?.first?["sender"] as? String == "9@lid")
    }

    @Test func aMissingServiceIsReportedAsUnavailable() async throws {
        let client = WhatsMeowClient(serviceName: "com.example.no-such-service-\(UUID().uuidString)")
        do {
            _ = try await client.accounts()
            Issue.record("expected an error")
        } catch let error as WhatsMeowError {
            #expect(error.code == WhatsMeowError.serviceUnavailableCode)
        }
    }
}

@Suite("Events and envelopes")
struct EventTests {
    @Test func decodesEveryEventType() throws {
        func event(_ json: String) throws -> WhatsMeowEvent { try WhatsMeowEvent(json: Data(json.utf8)) }

        #expect(try event(#"{"type":"account_state","account":"1","state":"connected","detail":""}"#)
                == .accountState(account: "1", state: "connected", detail: nil))
        #expect(try event(#"{"type":"pair_qr","session":"S","code":"2@x","timeoutSeconds":20}"#) == .pairQR(session: "S", code: "2@x"))
        #expect(try event(#"{"type":"pair_code","session":"S","code":"ABCD1234"}"#) == .pairCode(session: "S", code: "ABCD1234"))
        #expect(try event(#"{"type":"pair_success","session":"S","account":"1","pushName":""}"#)
                == .pairSuccess(session: "S", account: "1", pushName: nil))
        #expect(try event(#"{"type":"pair_failed","session":"S","reason":"timeout","message":"expired"}"#)
                == .pairFailed(session: "S", reason: "timeout", message: "expired"))
        #expect(try event(#"{"type":"chats","account":"1","chats":[{"jid":"g@g.us","name":"Team","isGroup":true,"unreadCount":3}]}"#)
                == .chats(account: "1", chats: [WhatsMeowChat(jid: "g@g.us", name: "Team", isGroup: true, unreadCount: 3)]))
        #expect(try event(#"{"type":"receipt","account":"1","chat":"c","ids":null,"receiptType":"read","fromMe":false,"timestamp":1}"#)
                == .receipt(account: "1", chat: "c", ids: [], receiptType: "read", fromMe: false))
        #expect(try event(#"{"type":"contacts_changed","account":"1"}"#) == .contactsChanged(account: "1"))
        #expect(try event(#"{"type":"log","level":"warning","module":"m","message":"x"}"#) == .log(level: "warning", module: "m", message: "x"))
        #expect(try event(#"{"type":"from_the_future"}"#) == .unknown("from_the_future"))

        guard case .messages(_, let source, let messages) = try event("""
            {"type":"messages","account":"1","source":"history","messages":[{"id":"A","chat":"2@s.whatsapp.net",
            "sender":"2@s.whatsapp.net","fromMe":false,"isGroup":false,"timestamp":7,"kind":"document","text":"cv",
            "media":{"mimeType":"application/pdf","fileName":"cv.pdf","fileSize":9,"raw":"AQID"}}]}
            """) else { Issue.record("wrong case"); return }
        #expect(source == "history")
        #expect(messages.first?.media?.raw == Data([1, 2, 3]))
        #expect(messages.first?.wireSender == "2@s.whatsapp.net")
    }

    @Test func envelopes() throws {
        #expect(String(decoding: try WhatsMeowEnvelope.result(Data(#"{"result":[1,2]}"#.utf8)), as: UTF8.self) == "[1,2]")
        #expect(String(decoding: try WhatsMeowEnvelope.result(Data(#"{"result":"x"}"#.utf8)), as: UTF8.self) == #""x""#)
        #expect(throws: WhatsMeowError(code: "c", message: "m")) {
            _ = try WhatsMeowEnvelope.result(Data(#"{"error":{"code":"c","message":"m"}}"#.utf8))
        }
    }
}
