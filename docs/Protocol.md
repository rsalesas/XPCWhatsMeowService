# Protocol

The methods and events the Go library speaks. `WhatsMeowClient` wraps each method in a typed call;
`WhatsMeowClient.call(_:arguments:)` reaches them directly.

Every reply is `{"result": …}` or `{"error": {"code": "…", "message": "…"}}`. Codes are stable;
messages are for people.

Accounts are phone numbers as digits (`"15551234567"`). Chats and senders are JIDs.

## Start options

| Field | Type | |
|---|---|---|
| `databasePath` | string | Required. Created if missing |
| `deviceName` | string | Shown under Linked Devices. Default `XPCWhatsMeowService` |
| `fullHistory` | bool | Full history sync when linking. Default `true` |
| `historyDays` | number | With `fullHistory`. Default `365` |

Result: `{"accounts": ["15551234567", …]}` — or, from the XPC service when it was already running,
`{"alreadyRunning": true}`.

## Methods

| Method | Arguments | Result |
|---|---|---|
| `accounts` | — | `[{account, jid, lid?, pushName?, businessName?, platform?, connected, loggedIn}]` |
| `pair_start` | `{phone?}` | `{session}` — then `pair_qr`/`pair_code` events, ending in `pair_success` or `pair_failed` |
| `pair_cancel` | `{session}` | `{}` |
| `logout` | `{account}` | `{account, unlinkedOnPhone}` — keys are deleted either way |
| `reconnect` | `{account}` | `{}` |
| `send_text` | `{account, to, text, replyTo?: {id, sender, text}}` | `{account, chat, id, timestamp, message?}` |
| `send_media` | `{account, to, path, kind, mimeType, fileName?, caption?, seconds?, width?, height?, thumbnail?, replyTo?}` | as `send_text` |
| `react` | `{account, chat, sender, fromMe, id, emoji}` | as `send_text` |
| `mark_read` | `{account, chat, messages: [{id, sender}]}` | `{}` |
| `download` | `{account, raw, path}` | `{path, size}` |
| `contacts` | `{account}` | `[{jid, phone?, firstName?, fullName?, pushName?, businessName?}]` |
| `groups` | `{account}` | `[{jid, name, topic?, created?, owner?, isAnnounce, isLocked, participantCount}]` |
| `group_info` | `{account, jid}` | as `groups`, plus `participants: [{jid, phone?, lid?, isAdmin, isSuperAdmin, displayName?}]` |
| `resolve` | `{account, phones}` | `[{query, jid, isOnWhatsApp}]` |
| `phones_for_lids` | `{account, lids}` | `[{lid, phone}]` — only the LIDs whatsmeow has a phone number for; read from its store, nothing sent |

Notes:

- `to` is a JID, or a phone number in international format that WhatsApp is asked about first
  (`not_on_whatsapp` if it isn't registered). Names are never accepted.
- `kind` for `send_media` is `image`, `video`, `audio`, `voice` or `document`. Audio and voice
  cannot have a caption. `thumbnail` is a small JPEG, base64.
- `react` and `mark_read` take the chat and sender **as received** — `rawChat`/`rawSender` when a
  message has them.
- Chats and senders are phone-number JIDs where the LID mapping is known when a message is
  converted. History sync saves its blob's mappings before converting it, but a chat whose number
  WhatsApp only revealed later stays a LID in what was already emitted: `phones_for_lids` lets the
  client re-file those.
- `download`'s `raw` is a message's `media.raw`, base64. The decrypted file is written to `path`
  (via a `.part` file, renamed into place); `media_expired` means WhatsApp no longer has it.

### Error codes

`not_started`, `already_started`, `unknown_method`, `invalid_argument`, `unknown_account`,
`not_connected`, `invalid_recipient`, `lookup_failed`, `not_on_whatsapp`, `send_failed`,
`send_refused` (the server answered the send with an error code, so nothing was delivered),
`upload_failed`, `file_unreadable`, `download_failed`, `media_expired`, `write_failed`,
`request_failed`, `pairing_failed`, `connect_failed`, `database`, `panic` — and, from the client,
`service_unavailable` and `decoding`.

## Events

Each is a JSON object with a `type`.

| Type | Fields |
|---|---|
| `account_state` | `account, state, detail` — `connected`, `disconnected` (reconnects by itself), `logged_out` (keys gone), `stream_replaced`, `temporarily_banned`, `connect_failure`, `client_outdated` |
| `pair_qr` | `session, code, timeoutSeconds` |
| `pair_code` | `session, code` |
| `pair_success` | `session, account, pushName` |
| `pair_failed` | `session, reason, message` |
| `messages` | `account, source` (`live`, `history`, `sent`), `messages` |
| `chats` | `account, chats: [{jid, name?, isGroup, unreadCount?, archived?}]` |
| `receipt` | `account, chat, ids, receiptType` (`""` delivered, `read`, `played`, `read-self`, `played-self`), `fromMe, timestamp` |
| `contacts_changed` | `account` |
| `history_progress` | `account, syncType, progress` (0–100) |
| `log` | `level, module, message` — whatsmeow's own log |

The client adds `.serviceRestarted` when it had to relaunch the service.

### A message

```json
{
  "id": "3EB0C7…", "chat": "15550100001@s.whatsapp.net", "sender": "15550100001@s.whatsapp.net",
  "rawChat": "21887…@lid", "rawSender": "21887…@lid", "pushName": "Alex",
  "fromMe": false, "isGroup": false, "timestamp": 1762177200,
  "kind": "image", "text": "the caption", "quotedId": "3EB0A1…",
  "media": {"mimeType": "image/jpeg", "fileSize": 182344, "width": 1280, "height": 960, "raw": "CgV…"}
}
```

`kind` is one of `text`, `image`, `video`, `gif`, `audio`, `voice`, `document`, `sticker`,
`location`, `contact`, `poll`, `reaction`, `edit`, `revoke`. Status updates, channel posts and
protocol housekeeping are never delivered.
