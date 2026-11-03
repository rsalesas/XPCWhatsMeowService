package main

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
)

// MARK: - Accounts

// account is one linked WhatsApp device: one of a phone's companion slots, held here.
type account struct {
	client *whatsmeow.Client
}

// id is the account's phone number (the device JID's user part), or "" before pairing
// has completed. Read from the store each time because pairing fills it in under us.
func (a *account) id() string {
	if a.client.Store.ID == nil {
		return ""
	}
	return a.client.Store.ID.User
}

func (b *bridge) newAccount(device *store.Device) *account {
	client := whatsmeow.NewClient(device, b.log.Sub("Client"))
	client.EnableAutoReconnect = true
	client.AutomaticMessageRerequestFromPhone = true
	acct := &account{client: client}
	client.AddEventHandler(func(evt any) { b.handleEvent(acct, evt) })
	return acct
}

// lookup finds a linked account by phone number.
func (b *bridge) lookup(id string) (*account, error) {
	id = digits(id)
	b.mu.Lock()
	defer b.mu.Unlock()
	acct, ok := b.accounts[id]
	if !ok {
		return nil, fail("unknown_account", "no linked WhatsApp account %s", id)
	}
	return acct, nil
}

// connected is lookup plus the precondition every network operation shares.
func (b *bridge) connected(id string) (*account, error) {
	acct, err := b.lookup(id)
	if err != nil {
		return nil, err
	}
	if !acct.client.IsConnected() || !acct.client.IsLoggedIn() {
		return nil, fail("not_connected", "WhatsApp account %s is not connected right now", acct.id())
	}
	return acct, nil
}

type accountInfo struct {
	Account      string `json:"account"`
	JID          string `json:"jid"`
	LID          string `json:"lid,omitempty"`
	PushName     string `json:"pushName,omitempty"`
	BusinessName string `json:"businessName,omitempty"`
	Platform     string `json:"platform,omitempty"`
	Connected    bool   `json:"connected"`
	LoggedIn     bool   `json:"loggedIn"`
}

func (b *bridge) listAccounts() []accountInfo {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make([]accountInfo, 0, len(b.accounts))
	for id, acct := range b.accounts {
		s := acct.client.Store
		info := accountInfo{
			Account:      id,
			PushName:     s.PushName,
			BusinessName: s.BusinessName,
			Platform:     s.Platform,
			Connected:    acct.client.IsConnected(),
			LoggedIn:     acct.client.IsLoggedIn(),
		}
		if s.ID != nil {
			info.JID = s.ID.ToNonAD().String()
		}
		if !s.LID.IsEmpty() {
			info.LID = s.LID.ToNonAD().String()
		}
		out = append(out, info)
	}
	return out
}

type accountArgs struct {
	Account string `json:"account"`
}

// logout unlinks the device: the phone drops it from Linked Devices and the local keys
// are deleted. If the server can't be reached the local keys go anyway — the user asked
// for this account to be gone, and keeping working credentials behind would be worse.
func (b *bridge) logout(args accountArgs) (any, error) {
	acct, err := b.lookup(args.Account)
	if err != nil {
		return nil, err
	}
	id := acct.id()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	remote := true
	if err := acct.client.Logout(ctx); err != nil {
		remote = false
		acct.client.Disconnect()
		if acct.client.Store.ID != nil {
			if derr := acct.client.Store.Delete(ctx); derr != nil {
				return nil, fail("database", "could not delete the local WhatsApp session: %v", derr)
			}
		}
	}
	b.forget(id)
	b.emitState(id, "logged_out", "unlinked by this app")
	return map[string]any{"account": id, "unlinkedOnPhone": remote}, nil
}

func (b *bridge) reconnect(args accountArgs) (any, error) {
	acct, err := b.lookup(args.Account)
	if err != nil {
		return nil, err
	}
	acct.client.Disconnect()
	if err := acct.client.Connect(); err != nil {
		return nil, fail("connect_failed", "could not reconnect: %v", err)
	}
	return nil, nil
}

func (b *bridge) forget(id string) {
	b.mu.Lock()
	delete(b.accounts, id)
	b.mu.Unlock()
}

// MARK: - Pairing

type pairing struct {
	id     string
	client *whatsmeow.Client
	cancel context.CancelFunc
}

type pairStartArgs struct {
	// Phone, when given, asks for an 8-character code to type on the phone instead of a
	// QR code to scan. QR codes are still produced either way; that's how whatsmeow
	// keeps the login socket open.
	Phone string `json:"phone"`
}

// pairStart links a new device. Progress arrives as pair_qr / pair_code events and ends
// with exactly one pair_success or pair_failed carrying the same session id.
func (b *bridge) pairStart(args pairStartArgs) (any, error) {
	phone := digits(args.Phone)
	if args.Phone != "" && (len(phone) < 7 || strings.HasPrefix(phone, "0")) {
		return nil, fail("invalid_argument",
			"%q is not a phone number in international format (country code first, no leading 0)", args.Phone)
	}

	device := b.container.NewDevice()
	acct := b.newAccount(device)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	session := uuid.NewString()

	qr, err := acct.client.GetQRChannel(ctx)
	if err != nil {
		cancel()
		return nil, fail("pairing_failed", "could not start pairing: %v", err)
	}
	if err := acct.client.Connect(); err != nil {
		cancel()
		return nil, fail("connect_failed", "could not reach WhatsApp: %v", err)
	}

	p := &pairing{id: session, client: acct.client, cancel: cancel}
	b.mu.Lock()
	b.pairings[session] = p
	b.mu.Unlock()

	go b.runPairing(ctx, p, acct, qr, phone)
	return map[string]any{"session": session}, nil
}

func (b *bridge) runPairing(ctx context.Context, p *pairing, acct *account, qr <-chan whatsmeow.QRChannelItem, phone string) {
	defer func() {
		p.cancel()
		b.mu.Lock()
		delete(b.pairings, p.id)
		b.mu.Unlock()
	}()

	codeRequested := false
	finished := false
	for item := range qr {
		switch item.Event {
		case whatsmeow.QRChannelEventCode:
			b.emit(map[string]any{
				"type": "pair_qr", "session": p.id, "code": item.Code,
				"timeoutSeconds": int(item.Timeout.Seconds()),
			})
			// The first QR code means the login socket is fully up — the point at which
			// whatsmeow says a phone-number code may be requested.
			if phone != "" && !codeRequested {
				codeRequested = true
				go func() {
					code, err := acct.client.PairPhone(ctx, phone, true, whatsmeow.PairClientChrome, "Chrome (Mac OS)")
					if err != nil {
						b.emit(map[string]any{"type": "pair_failed", "session": p.id, "reason": "phone_code", "message": err.Error()})
						acct.client.Disconnect()
						return
					}
					b.emit(map[string]any{"type": "pair_code", "session": p.id, "code": code})
				}()
			}
		case whatsmeow.QRChannelSuccess.Event:
			finished = true
			id := acct.id()
			b.mu.Lock()
			b.accounts[id] = acct
			b.mu.Unlock()
			b.emit(map[string]any{
				"type": "pair_success", "session": p.id, "account": id,
				"pushName": acct.client.Store.PushName,
			})
		case whatsmeow.QRChannelEventError:
			finished = true
			message := "pairing failed"
			if item.Error != nil {
				message = item.Error.Error()
			}
			b.emit(map[string]any{"type": "pair_failed", "session": p.id, "reason": "error", "message": message})
		default:
			// timeout, err-client-outdated, err-unexpected-state, passkey requests (which
			// a desktop companion cannot answer)…
			finished = true
			b.emit(map[string]any{"type": "pair_failed", "session": p.id, "reason": item.Event, "message": describePairFailure(item.Event)})
		}
	}

	if !finished {
		b.emit(map[string]any{"type": "pair_failed", "session": p.id, "reason": "cancelled", "message": "pairing was cancelled"})
	}
	if acct.id() == "" {
		acct.client.Disconnect()
	}
}

func describePairFailure(event string) string {
	switch event {
	case whatsmeow.QRChannelTimeout.Event:
		return "the code expired before it was used — start again"
	case whatsmeow.QRChannelClientOutdated.Event:
		return "WhatsApp rejected this version of the bridge as outdated — the app needs an update"
	case whatsmeow.QRChannelScannedWithoutMultidevice.Event:
		return "the phone scanned the code without multi-device support enabled"
	case whatsmeow.QRChannelEventPasskeyRequest:
		return "the phone asked for a passkey, which this app can't provide — link with the QR code instead"
	default:
		return fmt.Sprintf("pairing ended unexpectedly (%s)", event)
	}
}

type sessionArgs struct {
	Session string `json:"session"`
}

func (b *bridge) pairCancel(args sessionArgs) (any, error) {
	b.mu.Lock()
	p, ok := b.pairings[args.Session]
	b.mu.Unlock()
	if !ok {
		return nil, nil // already over; cancelling twice is not an error
	}
	p.cancel()
	if p.client.Store.ID == nil {
		p.client.Disconnect()
	}
	return nil, nil
}

// MARK: - Events

func (b *bridge) emitState(id, state, detail string) {
	b.emit(map[string]any{"type": "account_state", "account": id, "state": state, "detail": detail})
}

func (b *bridge) handleEvent(acct *account, evt any) {
	id := acct.id()
	if id == "" {
		return // pairing traffic; the QR channel reports it
	}
	ctx := context.Background()

	switch e := evt.(type) {
	case *events.Connected:
		b.emitState(id, "connected", "")
	case *events.Disconnected:
		b.emitState(id, "disconnected", "")
	case *events.KeepAliveTimeout:
		b.emitState(id, "disconnected", fmt.Sprintf("keep-alive timed out %d times", e.ErrorCount))
	case *events.LoggedOut:
		// whatsmeow has already deleted the device's keys; drop the account here too.
		b.forget(id)
		b.emitState(id, "logged_out", e.Reason.String())
	case *events.StreamReplaced:
		// Another connection took over this device identity. whatsmeow does not
		// reconnect, which is right: two would just evict each other forever.
		b.emitState(id, "stream_replaced", "another connection is using this WhatsApp link")
	case *events.TemporaryBan:
		b.emitState(id, "temporarily_banned", e.String())
	case *events.ConnectFailure:
		b.emitState(id, "connect_failure", fmt.Sprintf("%s %s", e.Reason.String(), e.Message))
	case *events.ClientOutdated:
		b.emitState(id, "client_outdated", "WhatsApp rejected this version of the bridge as outdated")

	case *events.Message:
		if m := convertMessage(ctx, acct.client, e); m != nil {
			b.emit(messagesEvent{Type: "messages", Account: id, Source: "live", Messages: []*message{m}})
		}
	case *events.HistorySync:
		b.handleHistorySync(ctx, acct, e)
	case *events.Receipt:
		b.emitReceipt(ctx, acct, e)

	case *events.PushName, *events.Contact, *events.BusinessName:
		b.emit(map[string]any{"type": "contacts_changed", "account": id})
	case *events.JoinedGroup:
		b.emit(chatsEvent{Type: "chats", Account: id, Chats: []chatInfo{{JID: e.JID.String(), Name: e.Name, IsGroup: true}}})
	case *events.GroupInfo:
		if e.Name != nil {
			b.emit(chatsEvent{Type: "chats", Account: id, Chats: []chatInfo{{JID: e.JID.String(), Name: e.Name.Name, IsGroup: true}}})
		}
	}
}

// MARK: - Logging

// eventLogger routes whatsmeow's log lines to Swift as "log" events, so they land in the
// app's own log alongside everything else instead of on a stdout nobody reads.
type eventLogger struct {
	bridge *bridge
	module string
}

func (l *eventLogger) emit(level, msg string, args []any) {
	l.bridge.emit(map[string]any{"type": "log", "level": level, "module": l.module, "message": fmt.Sprintf(msg, args...)})
}

func (l *eventLogger) Errorf(msg string, args ...any) { l.emit("error", msg, args) }
func (l *eventLogger) Warnf(msg string, args ...any)  { l.emit("warning", msg, args) }
func (l *eventLogger) Infof(msg string, args ...any)  { l.emit("info", msg, args) }
func (l *eventLogger) Debugf(string, ...any)          {}
func (l *eventLogger) Sub(module string) waLog.Logger {
	return &eventLogger{bridge: l.bridge, module: l.module + "/" + module}
}

// MARK: - Helpers

// digits keeps only 0-9: "+1 (555) 010-0000" → "15550100000".
func digits(s string) string {
	var sb strings.Builder
	for _, r := range s {
		if r >= '0' && r <= '9' {
			sb.WriteRune(r)
		}
	}
	return sb.String()
}

// pnFor maps a LID ("hidden user") JID to the phone-number JID it stands for, when
// whatsmeow knows the mapping. WhatsApp now addresses many chats by LID; without this one
// conversation would split in two depending on which form a message arrived under.
func pnFor(ctx context.Context, client *whatsmeow.Client, jid, alt types.JID) types.JID {
	jid = jid.ToNonAD()
	if jid.Server != types.HiddenUserServer {
		return jid
	}
	if !alt.IsEmpty() && alt.Server == types.DefaultUserServer {
		return alt.ToNonAD()
	}
	if pn, err := client.Store.LIDs.GetPNForLID(ctx, jid); err == nil && !pn.IsEmpty() {
		return pn.ToNonAD()
	}
	return jid
}
