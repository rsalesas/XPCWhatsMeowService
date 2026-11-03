# Testing

Four layers, from cheapest to most real.

| | What | Command |
|---|---|---|
| Go | Message normalisation: every kind, modifiers, dropped housekeeping, media references | `cd Go/wabridge && go test ./...` |
| Client | `XPCWhatsMeow` against a mock service on an anonymous XPC listener — arguments, typed replies, error codes, event order. No Go. | `swift test --filter XPCWhatsMeowTests` |
| Library | The real Go library through the C ABI, then the whole stack — client, real service listener, Go — over a real XPC connection in one process | `swift test --filter XPCWhatsMeowServiceKitTests` |
| End to end | The demo app, launching its embedded `.xpc` through launchd | `scripts/end-to-end.sh` |

Everything except the end-to-end check runs offline. Two tests talk to WhatsApp's servers — they
fetch a real pairing QR code, then cancel — and only run when asked:

```bash
XPCWHATSMEOW_LIVE=1 swift test
scripts/end-to-end.sh            # add --offline to skip the network step
```

Neither links a device or touches an account. Anything that would — sending, history sync, media —
needs a phone, and is checked by hand with the demo app.

The library is process-global, so every test that touches it is in one serialized suite.
