# Integrating XPCWhatsMeowService into an app

Two parts, because a Swift package cannot carry an XPC service.

## 1. The client

Add the package — a git submodule is the simplest way to pin it, since the Go library has to be
built from it anyway:

```bash
git submodule add https://github.com/rsalesas/XPCWhatsMeowService.git
XPCWhatsMeowService/scripts/build-xcframework.sh
```

```swift
// Package.swift
.package(path: "XPCWhatsMeowService"),
// your app target:
.product(name: "XPCWhatsMeow", package: "XPCWhatsMeowService"),
```

Link **only `XPCWhatsMeow`** (it brings `XPCWhatsMeowProtocol`). Never link
`XPCWhatsMeowServiceKit` into the app — that is the module with whatsmeow and libsignal in it.

## 2. The service

The app needs `XPCWhatsMeowService.xpc` in `Contents/XPCServices/`. Either:

- **build it as a target of your own project** — an XPC Service target whose only source is
  `XPCService/main.swift`, linking the `XPCWhatsMeowServiceKit` product, with `XPCService/Info.plist`
  and the files in `XPCService/Licenses/` plus `NOTICE` as resources. Make your app depend on it and
  Xcode embeds it. With [XcodeGen](https://github.com/yonaskolb/XcodeGen), copy the
  `XPCWhatsMeowService` target from this repository's `project.yml` and point its paths into the
  submodule. Building it yourself means it is signed with your identity, which is what the service's
  same-team check expects;
- or build this repository's `XPCWhatsMeowService` scheme and add the `.xpc` with a Copy Files phase
  (destination *XPC Services*), re-signing it with your identity.

Without it every call fails with `WhatsMeowError` code `service_unavailable`.

Run `scripts/build-xcframework.sh` as a pre-build step of that target — it is a no-op when nothing
changed. Xcode resolves the package before any build phase runs, though, so on a fresh clone run it
once by hand first.

## Service name

`WhatsMeowClient()` connects to `com.siliconink.XPCWhatsMeowService`. If you give the service
your own bundle identifier, pass it:

```swift
let whatsApp = WhatsMeowClient(serviceName: "com.example.MyApp.WhatsApp")
```

## Starting

```swift
try await whatsApp.start(WhatsMeowStartOptions(
    databasePath: appSupport.appendingPathComponent("whatsapp-session.db").path,
    deviceName: "My App",       // shown in the phone's Linked Devices
    fullHistory: true,          // ask for a full sync when linking (default)
    historyDays: 365
)) { event in … }
```

- **The session database is a credential.** Put it somewhere only the user can read and make it
  0600. The service creates it with SQLite's defaults.
- **Start once, early, and keep the client.** Accounts connect when `start` is called and stay
  connected until `stop` or the app quits. Events start flowing immediately — history in particular
  arrives in bursts for minutes after linking.
- **Handle events quickly.** They are delivered in order on a private queue; hop to your own actor or
  queue before doing anything slow.

## Storing messages

The service does not keep history. Every message arrives once, in a `.messages` event, with `source`
`live`, `history` or `sent` (your own sends — whatsmeow does not echo them). Record them as they
come.

Three kinds modify an earlier message instead of standing alone: `reaction` (text is the emoji,
empty to remove), `edit` (text is the new content) and `revoke` (deleted for everyone). They carry
the target in `targetId`, and **may arrive before their target** — history chunks are not ordered.
Keep unmatched ones until the target appears. Honour revokes: drop the text *and* the media
reference, which contains the key that decrypts it.

## Sandboxing

The service is not sandboxed, because it reads files to send and writes downloads by path. If your
app is sandboxed, that is a way out of its sandbox, and App Review will notice. Either keep sending
and downloading inside your app's container, or sandbox the service (`com.apple.security.app-sandbox`
plus `network.client`) and pass it paths inside a shared app-group container.

## Licensing

Your app links MIT code only. The service you ship is GPL v3 — keep its notices (the bundle carries
them) and point at this repository as the source. See [NOTICE](../NOTICE).
