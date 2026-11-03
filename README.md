# XPCWhatsMeowService

## WhatsApp for macOS apps, behind an XPC service

[whatsmeow](https://github.com/tulir/whatsmeow) — the Go implementation of the protocol WhatsApp's
own web and desktop clients speak — as a library inside an XPC service, with a typed Swift client
in front of it. Your app links the client; the service holds the WhatsApp connection, and it is the
only binary that contains whatsmeow.

```swift
import XPCWhatsMeow

let whatsApp = WhatsMeowClient()
try await whatsApp.start(WhatsMeowStartOptions(databasePath: sessionPath, deviceName: "My App")) { event in
    switch event {
    case .pairQR(_, let code):            showQRCode(code)
    case .messages(let account, _, let messages): store(messages, for: account)
    default: break
    }
}

let session = try await whatsApp.startPairing()      // QR codes arrive as events
// … the user scans it in WhatsApp › Linked Devices …
try await whatsApp.sendText(account: "15551234567", to: "+44 20 7946 0000", text: "Hello from my Mac")
```

## Why an XPC service

whatsmeow depends on [libsignal](https://github.com/tulir/libsignal), which is **GPL v3**. Linking
it into your app makes your app a GPL work. Putting it in its own process does not: an app that
talks to a separate program over XPC is not a combined work with it, and does not have to publish
its own source. The process boundary is the licensing boundary, and this project is built around
it — see [NOTICE](NOTICE), and [Architecture](docs/Architecture.md) for how.

It is the same arrangement as [XPCFFmpegService](https://github.com/rsalesas/XPCFFmpegService), with
one difference: FFmpeg had to run as a separate executable per job, because it cannot safely be
used as a library. whatsmeow can, so here the Go code is a static library linked straight into the
service, and the service is the only extra process.

## What it does

| | |
|---|---|
| **Linking** | QR code, or an 8-character code typed on the phone. Several accounts at once |
| **History** | The history sync the phone sends when a device is linked — full, or recent only |
| **Messages** | Text, photos, video, GIFs, voice notes, audio, documents, stickers, locations, contacts, polls — live, from history, and your own sends |
| **Changes** | Reactions, edits and deletes-for-everyone, each naming the message it changes |
| **Receipts** | Delivered, read and played — and reads on your other devices |
| **Sending** | Text, replies, files (photo, video, audio, voice note, document), reactions, read receipts |
| **Media** | Downloaded and decrypted straight to a file; bytes never cross XPC |
| **Contacts & groups** | Address-book and push names, group lists and members |
| **LIDs** | WhatsApp's hidden-user IDs mapped back to phone numbers where known, with the original kept for receipts |
| **Recovery** | Reconnects by itself; if the service dies, the client restarts it and says so |

It keeps **no message history** of its own — neither does WhatsApp offer one to a linked device
after the initial sync. Every message arrives once, as an event; storing it is your app's job.

## Building

Needs Xcode 16+ and [Go](https://go.dev/dl/) (any recent version: `go.mod` asks for the toolchain
it needs and Go fetches it).

```bash
scripts/build-xcframework.sh     # Go → Frameworks/CWhatsMeow.xcframework (universal, ~40 MB)
swift test                       # the Swift tests (Go tests: cd Go/wabridge && go test ./...)
xcodegen generate                # XPCWhatsMeowService.xcodeproj, from project.yml
xcodebuild -project XPCWhatsMeowService.xcodeproj -scheme WhatsMeowDemo build
```

The xcframework is not checked in; run the script once after cloning. It does nothing when the
framework is already newer than the Go sources, so build phases call it freely.

## Layout

| | |
|---|---|
| `Sources/XPCWhatsMeow/` | What an app links: `WhatsMeowClient`, typed models and events. No whatsmeow inside. |
| `Sources/XPCWhatsMeowProtocol/` | The XPC interface both sides share. |
| `Sources/XPCWhatsMeowServiceKit/` | What the service links: Swift over the Go library, and the XPC listener. |
| `Go/wabridge/` | whatsmeow behind a four-function C ABI (`wabridge.h`). |
| `XPCService/` | The service's `main.swift`, Info.plist, and the licence texts it ships. |
| `Demo/` | A small app embedding the service; also the end-to-end check (`--check`). |
| `docs/` | [Integrating](docs/Integrating.md), [Architecture](docs/Architecture.md), [Protocol](docs/Protocol.md), [Testing](docs/Testing.md). |

## Before you ship it

- **The service binary is GPL v3.** Ship its notices (the bundle carries them), and point at this
  repository as its source. Your app's own code is unaffected — see [NOTICE](NOTICE).
- **WhatsApp does not permit unofficial clients**, and may restrict or ban accounts that use them —
  particularly ones that send in bulk or to people who haven't messaged them first. Tell your users.
- **The session database is a credential.** It holds every linked device's keys; anyone who copies it
  can read and send as those accounts. Keep it somewhere private (mode 0600).

## Licence

MIT for the source in this repository — [LICENSE](LICENSE). A built service is GPL v3 —
[NOTICE](NOTICE). Not affiliated with or endorsed by WhatsApp or Meta.
