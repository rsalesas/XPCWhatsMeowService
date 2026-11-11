// Package main is XPCWhatsMeowService's Go library: whatsmeow behind a four-function C ABI
// (see wabridge.h), built as a static c-archive and linked into the XPC service — the one
// process that contains whatsmeow, and so the one binary under the GPL.
//
// Shape of the contract:
//   - Swift calls WA_Call(method, json) and gets {"result": …} or {"error": …} back.
//   - Go pushes everything asynchronous — QR codes, messages, connection changes — through
//     the one callback registered by WA_Start, again as JSON.
//
// The bridge keeps no message history of its own. whatsmeow persists only what the
// protocol needs (keys, sessions, contacts, LID mappings); every message is handed to the
// client as it arrives, and recording it is the client's job. That keeps storage, schema
// and search with the app, which knows what it wants to keep.
package main

/*
#include <stdlib.h>

// Must match wabridge.h. That header is not included here because it declares the
// exports with `const char *` parameters (what Swift wants to pass), while cgo generates
// them as `char *`; the two are ABI-identical but a C compiler rejects seeing both.
typedef void (*wa_event_callback)(void *context, const char *json);

// Go cannot call a C function pointer directly; this trampoline does it for us.
static inline void wa_deliver(wa_event_callback callback, void *context, const char *json) {
	if (callback) callback(context, json);
}
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"sync"
	"unsafe"

	"go.mau.fi/whatsmeow/proto/waCompanionReg"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"google.golang.org/protobuf/proto"
	_ "modernc.org/sqlite"
)

// A c-archive still needs a main package with a main function; it is never run.
func main() {}

// MARK: - Errors and the response envelope

// bridgeError is the only error shape that crosses the ABI. `code` is stable and meant
// for Swift to switch on; `message` is for humans and may change.
type bridgeError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *bridgeError) Error() string { return e.Message }

func fail(code, format string, args ...any) *bridgeError {
	return &bridgeError{Code: code, Message: fmt.Sprintf(format, args...)}
}

type envelope struct {
	Result any          `json:"result,omitempty"`
	Error  *bridgeError `json:"error,omitempty"`
}

// respond runs an operation and wraps its outcome for the ABI. A panic becomes an error
// envelope rather than taking the whole service down with it, and every linked account's
// connection with it.
func respond(run func() (any, error)) (out *C.char) {
	defer func() {
		if r := recover(); r != nil {
			out = encode(envelope{Error: fail("panic", "WhatsApp bridge panicked: %v", r)})
		}
	}()
	result, err := run()
	if err != nil {
		var be *bridgeError
		if !errors.As(err, &be) {
			be = fail("failed", "%s", err.Error())
		}
		return encode(envelope{Error: be})
	}
	if result == nil {
		result = struct{}{}
	}
	return encode(envelope{Result: result})
}

func encode(value any) *C.char {
	data, err := json.Marshal(value)
	if err != nil {
		data = []byte(`{"error":{"code":"encoding","message":"could not encode the bridge response"}}`)
	}
	return C.CString(string(data))
}

// MARK: - Bridge state

type bridge struct {
	container *sqlstore.Container
	log       *eventLogger

	mu       sync.Mutex
	accounts map[string]*account // keyed by the phone-number user part of the device JID
	pairings map[string]*pairing

	// emitMu serialises the callback, so Swift sees events in the order they happened,
	// and lets WA_Stop guarantee nothing is delivered after it returns.
	emitMu   sync.Mutex
	stopped  bool
	callback C.wa_event_callback
	context  unsafe.Pointer
}

var (
	globalMu sync.Mutex
	current  *bridge
)

func active() (*bridge, error) {
	globalMu.Lock()
	defer globalMu.Unlock()
	if current == nil {
		return nil, fail("not_started", "the WhatsApp bridge has not been started")
	}
	return current, nil
}

// emit hands one event to Swift. Safe from any goroutine.
func (b *bridge) emit(event any) {
	data, err := json.Marshal(event)
	if err != nil {
		return
	}
	cs := C.CString(string(data))
	defer C.free(unsafe.Pointer(cs))

	b.emitMu.Lock()
	defer b.emitMu.Unlock()
	if b.stopped {
		return
	}
	C.wa_deliver(b.callback, b.context, cs)
}

// MARK: - Exports

//export WA_Start
func WA_Start(optionsJSON *C.char, callback C.wa_event_callback, context unsafe.Pointer) *C.char {
	raw := []byte("{}")
	if optionsJSON != nil {
		raw = []byte(C.GoString(optionsJSON))
	}
	return respond(func() (any, error) {
		var options startOptions
		if err := json.Unmarshal(raw, &options); err != nil {
			return nil, fail("invalid_argument", "malformed start options: %v", err)
		}
		return start(options, callback, context)
	})
}

//export WA_Call
func WA_Call(method *C.char, argsJSON *C.char) *C.char {
	name := C.GoString(method)
	args := []byte("{}")
	if argsJSON != nil {
		args = []byte(C.GoString(argsJSON))
	}
	return respond(func() (any, error) {
		b, err := active()
		if err != nil {
			return nil, err
		}
		return b.dispatch(name, args)
	})
}

//export WA_Stop
func WA_Stop() {
	globalMu.Lock()
	b := current
	current = nil
	globalMu.Unlock()
	if b == nil {
		return
	}
	b.shutdown()
}

//export WA_Free
func WA_Free(pointer *C.char) {
	C.free(unsafe.Pointer(pointer))
}

// MARK: - Lifecycle

type startOptions struct {
	DatabasePath string `json:"databasePath"`
	DeviceName   string `json:"deviceName"`
	FullHistory  *bool  `json:"fullHistory"`
	HistoryDays  uint32 `json:"historyDays"`
}

func start(options startOptions, callback C.wa_event_callback, ctx unsafe.Pointer) (any, error) {
	globalMu.Lock()
	defer globalMu.Unlock()
	if current != nil {
		return nil, fail("already_started", "the WhatsApp bridge is already running")
	}
	dbPath := options.DatabasePath
	if dbPath == "" {
		return nil, fail("invalid_argument", "databasePath is required")
	}

	b := &bridge{
		accounts: map[string]*account{},
		pairings: map[string]*pairing{},
		callback: callback,
		context:  ctx,
	}
	b.log = &eventLogger{bridge: b, module: "whatsmeow"}
	configureDeviceProps(options)

	// modernc's pure-Go SQLite, not mattn's cgo one: mattn compiles its own copy of the
	// sqlite3_* symbols into this archive, which would then sit beside the system
	// libsqlite3 that GRDB links in the same process.
	dsn := (&url.URL{Scheme: "file", Path: dbPath}).String() +
		"?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=busy_timeout(10000)"
	container, err := sqlstore.New(context.Background(), "sqlite", dsn, b.log.Sub("Database"))
	if err != nil {
		return nil, fail("database", "could not open the WhatsApp session database: %v", err)
	}
	b.container = container

	devices, err := container.GetAllDevices(context.Background())
	if err != nil {
		_ = container.Close()
		return nil, fail("database", "could not read linked devices: %v", err)
	}

	ids := []string{}
	for _, device := range devices {
		acct := b.newAccount(device)
		id := acct.id()
		if id == "" {
			continue
		}
		b.accounts[id] = acct
		ids = append(ids, id)
		// Connecting dials the network; never make WA_Start wait for it.
		go func() {
			if err := acct.client.Connect(); err != nil {
				b.emitState(id, "connect_failure", err.Error())
			}
		}()
	}

	current = b
	return map[string]any{"accounts": ids}, nil
}

func (b *bridge) shutdown() {
	b.mu.Lock()
	accounts := make([]*account, 0, len(b.accounts))
	for _, a := range b.accounts {
		accounts = append(accounts, a)
	}
	pairings := make([]*pairing, 0, len(b.pairings))
	for _, p := range b.pairings {
		pairings = append(pairings, p)
	}
	b.mu.Unlock()

	// Stop delivering first: Swift may free the callback context as soon as we return.
	b.emitMu.Lock()
	b.stopped = true
	b.emitMu.Unlock()

	for _, p := range pairings {
		p.cancel()
		p.client.Disconnect()
	}
	for _, a := range accounts {
		a.client.Disconnect()
	}
	if b.container != nil {
		_ = b.container.Close()
	}
}

// configureDeviceProps sets what the phone shows under Linked Devices and how much
// history a newly linked device asks for. By default that is a full sync of the last year,
// so a freshly linked account has something to read.
func configureDeviceProps(options startOptions) {
	name := options.DeviceName
	if name == "" {
		name = "XPCWhatsMeowService"
	}
	store.SetOSInfo(name, [3]uint32{1, 0, 0})
	store.DeviceProps.PlatformType = waCompanionReg.DeviceProps_DESKTOP.Enum()
	full := options.FullHistory == nil || *options.FullHistory
	store.DeviceProps.RequireFullSync = proto.Bool(full)
	days := options.HistoryDays
	if days == 0 {
		days = 365
	}
	if full {
		store.DeviceProps.HistorySyncConfig.FullSyncDaysLimit = proto.Uint32(days)
	} else {
		store.DeviceProps.HistorySyncConfig.FullSyncDaysLimit = nil
	}
}

// MARK: - Dispatch

func (b *bridge) dispatch(method string, raw []byte) (any, error) {
	switch method {
	case "accounts":
		return b.listAccounts(), nil
	case "pair_start":
		return call(raw, b.pairStart)
	case "pair_cancel":
		return call(raw, b.pairCancel)
	case "logout":
		return call(raw, b.logout)
	case "reconnect":
		return call(raw, b.reconnect)
	case "send_text":
		return call(raw, b.sendText)
	case "send_media":
		return call(raw, b.sendMedia)
	case "react":
		return call(raw, b.react)
	case "mark_read":
		return call(raw, b.markRead)
	case "download":
		return call(raw, b.download)
	case "contacts":
		return call(raw, b.contacts)
	case "groups":
		return call(raw, b.groups)
	case "group_info":
		return call(raw, b.groupInfo)
	case "resolve":
		return call(raw, b.resolve)
	case "phones_for_lids":
		return call(raw, b.phonesForLIDs)
	default:
		return nil, fail("unknown_method", "unknown bridge method %q", method)
	}
}

// call decodes the JSON arguments for one operation and runs it.
func call[A any](raw []byte, run func(A) (any, error)) (any, error) {
	var args A
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &args); err != nil {
			return nil, fail("invalid_argument", "malformed arguments: %v", err)
		}
	}
	return run(args)
}
