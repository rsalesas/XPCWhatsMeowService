# Architecture

Two processes:

```
your app ──XPC──▶ XPCWhatsMeowService.xpc
(XPCWhatsMeow)     XPCWhatsMeowServiceKit
                   └─ libwabridge.a (Go: whatsmeow, libsignal, SQLite)
```

## Why a library, and why a service

whatsmeow is a well-behaved Go library: no process-global state beyond what the bridge itself
keeps, no `exit()` on bad input, cancellation through contexts. So unlike FFmpeg in
[XPCFFmpegService](https://github.com/rsalesas/XPCFFmpegService), it does not need a process per
job — it is built with `go build -buildmode=c-archive` and linked into the service's own binary.

The service exists for one reason: **licensing**. libsignal is GPL v3, and the GPL's reach ends at
the process boundary. The app links only `XPCWhatsMeow` and `XPCWhatsMeowProtocol`, which contain
no Go at all; everything whatsmeow touches lives in the `.xpc`. See [NOTICE](../NOTICE).

It also happens to be the right shape for WhatsApp. A linked device tolerates exactly one live
connection — a second one with the same keys makes the server drop the first (`stream_replaced`).
One long-lived service per app holds that connection, whatever the app does with its windows.

## The C ABI

`Go/wabridge/wabridge.h` is four functions:

| | |
|---|---|
| `WA_Start(options_json, callback, context)` | Open the session database, connect linked devices, register the event callback |
| `WA_Call(method, args_json)` | Run one operation; blocks until it finishes |
| `WA_Stop()` | Disconnect everything; no callback runs after it returns |
| `WA_Free(pointer)` | Release a string the library returned |

Everything with structure is JSON — every reply is `{"result": …}` or `{"error": {"code", "message"}}`.
That keeps the ABI from ever changing: a new operation is a case in Go's dispatcher and a method on
the Swift client, nothing else. [Protocol](Protocol.md) lists them.

Events (QR codes, messages, receipts, connection changes) go through the one callback, serialised
by a lock in Go so they arrive in the order they happened. `WA_Stop` takes the same lock, which is
what makes "nothing after it returns" true — the Swift side releases the callback's context
immediately afterwards.

A panic in an operation becomes an error envelope rather than an abort: the service also holds every
other account's connection.

### SQLite

whatsmeow needs a database for keys and sessions. The bridge uses modernc's pure-Go SQLite rather
than mattn's cgo one: the latter compiles its own copy of the `sqlite3_*` symbols into the archive,
which then share a process with whatever SQLite the rest of the binary links.

## XPC

`XPCWhatsMeowProtocol` is just as thin: `start(options:)`, `call(method:arguments:)`, `stop()` in
one direction and `receive(event:)` in the other, all carrying the same JSON as the C ABI. The
service never decodes a payload — it forwards bytes — so an app and a service from slightly
different versions disagree only where an operation actually changed.

The app exports an event receiver on its connection; the service sends every event to it. XPC keeps
messages on one connection in order, so ordering survives the hop.

### Lifetime

- The service begins an XPC transaction once started, so the system does not reclaim it as idle while
  it holds WhatsApp connections, and ends it on `stop`.
- If the app's connection ends — quit, crash — the service stops the library. Nobody is left to
  receive events, and an unattended session should not stay connected.
- If the *service* dies, the client gets an interruption, starts it again with the same options
  (backing off 0.5 s, 1 s, 2 s … to 30 s), and delivers `.serviceRestarted`. Accounts reconnect on
  their own; a pairing in progress is lost and has to be started again.
- A client that reconnects to a still-running service takes it over: `start` replies
  `"alreadyRunning": true` and events move to the new connection. Only the current owner's
  departure stops the library.

### Who may connect

An XPC service inside an app bundle is only reachable by that app's processes. On top of that the
service requires the client to be signed by the same team as itself
(`setCodeSigningRequirement`, checked against the audit token by the system), when it is signed by
a team at all — ad-hoc development builds skip it.

## Files: paths, not bytes

Sending a file names a path, and the service reads it; downloading media names a destination, and
the service writes it. Bytes never travel over XPC, which keeps a 100 MB video out of every message
buffer. It also means the service must be able to reach those paths: it is not sandboxed. If your
app is, see [Integrating](Integrating.md#sandboxing).

## Identities

- **Accounts** are the linked phone number, as bare digits (`15551234567`) — the user part of the
  device's JID.
- **Chats and senders** are JIDs: `…@s.whatsapp.net` for people, `…@g.us` for groups. WhatsApp
  increasingly addresses people by *LID* (`…@lid`), an identifier that hides the phone number. The
  bridge maps LIDs back to phone-number JIDs wherever whatsmeow knows the mapping, so one
  conversation does not split in two, and keeps the original in `rawChat`/`rawSender` — receipts and
  reactions must go to the address WhatsApp actually used.
- **Recipients** are a JID or a phone number. A number is checked against WhatsApp before sending. A
  name is never accepted: names are ambiguous, and an ambiguous recipient is how a message reaches the
  wrong person.
