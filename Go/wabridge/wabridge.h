// The C ABI of XPCWhatsMeowService's Go library — a thin layer over whatsmeow, built with
// `go build -buildmode=c-archive` and linked into one binary only: the XPC service. That
// process is the GPL boundary (whatsmeow depends on GPLv3 libsignal); an app using the
// service talks to it over XPC and contains none of this code.
//
// The surface is deliberately four functions wide. Everything with structure travels as
// UTF-8 JSON, so adding an operation changes the Go dispatcher and the Swift caller but
// never this header, and no Go type ever has to be mirrored in C.
//
// Ownership: every `char *` this library returns was allocated by it and must be released
// with WA_Free. Strings passed in are borrowed for the duration of the call only.

#ifndef WABRIDGE_H
#define WABRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Receives every asynchronous event (QR codes, messages, connection changes) as one JSON
/// object. Called from Go-owned threads, one event at a time and in order; `json` is only
/// valid until the callback returns, so copy it and return quickly.
typedef void (*wa_event_callback)(void *context, const char *json);

/// Opens the whatsmeow session database, registers `callback`, and connects every device
/// already linked in it. `options_json` is an object:
///   databasePath  (string, required) — the session database; created if missing
///   deviceName    (string)  — what the phone lists under Linked Devices
///   fullHistory   (bool)    — ask the phone for a full history sync when linking (default true)
///   historyDays   (number)  — with fullHistory, how many days back (default 365)
/// Returns a JSON envelope: {"result": …} or {"error": {"code": "…", "message": "…"}}.
/// Calling it twice without WA_Stop is an error.
char *WA_Start(const char *options_json, wa_event_callback callback, void *context);

/// Runs one operation. `method` names it and `args_json` carries its arguments as a JSON
/// object (NULL means {}). Blocks until the operation finishes — call it off the main
/// thread. Returns the same envelope as WA_Start.
char *WA_Call(const char *method, const char *args_json);

/// Disconnects every client and closes the database. No events are delivered after it
/// returns.
void WA_Stop(void);

/// Releases a string returned by WA_Start or WA_Call.
void WA_Free(char *pointer);

#ifdef __cplusplus
}
#endif

#endif
