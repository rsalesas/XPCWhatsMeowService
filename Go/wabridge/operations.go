package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

const networkTimeout = 60 * time.Second

// Sending media uploads the whole file first; give a large video room to finish.
const uploadTimeout = 10 * time.Minute

// MARK: - Recipients

// resolveRecipient turns what Swift was given into a JID it is safe to send to. A JID is
// taken as-is (after validation); anything else must be a phone number that WhatsApp
// confirms is registered. There is deliberately no name matching here: a name is
// ambiguous, and an ambiguous recipient is how a message reaches the wrong person.
func resolveRecipient(ctx context.Context, client *whatsmeow.Client, to string) (types.JID, error) {
	to = strings.TrimSpace(to)
	if strings.Contains(to, "@") {
		jid, err := types.ParseJID(to)
		if err != nil {
			return types.EmptyJID, fail("invalid_recipient", "%q is not a valid WhatsApp JID", to)
		}
		switch jid.Server {
		case types.DefaultUserServer, types.GroupServer, types.HiddenUserServer:
			return jid.ToNonAD(), nil
		default:
			return types.EmptyJID, fail("invalid_recipient", "can't send to %q: only people and groups are supported", to)
		}
	}

	number := digits(to)
	if len(number) < 7 || len(number) > 15 {
		return types.EmptyJID, fail("invalid_recipient",
			"%q is neither a WhatsApp JID nor a phone number in international format", to)
	}
	found, err := client.IsOnWhatsApp(ctx, []string{"+" + number})
	if err != nil {
		return types.EmptyJID, fail("lookup_failed", "could not check whether +%s is on WhatsApp: %v", number, err)
	}
	if len(found) == 0 || !found[0].IsIn {
		return types.EmptyJID, fail("not_on_whatsapp", "+%s is not registered on WhatsApp", number)
	}
	return found[0].JID.ToNonAD(), nil
}

type resolveArgs struct {
	Account string   `json:"account"`
	Phones  []string `json:"phones"`
}

func (b *bridge) resolve(args resolveArgs) (any, error) {
	acct, err := b.connected(args.Account)
	if err != nil {
		return nil, err
	}
	queries := make([]string, 0, len(args.Phones))
	for _, p := range args.Phones {
		queries = append(queries, "+"+digits(p))
	}
	ctx, cancel := context.WithTimeout(context.Background(), networkTimeout)
	defer cancel()
	found, err := acct.client.IsOnWhatsApp(ctx, queries)
	if err != nil {
		return nil, fail("lookup_failed", "%v", err)
	}
	out := []map[string]any{}
	for _, r := range found {
		out = append(out, map[string]any{"query": r.Query, "jid": r.JID.String(), "isOnWhatsApp": r.IsIn})
	}
	return out, nil
}

type lidsArgs struct {
	Account string   `json:"account"`
	LIDs    []string `json:"lids"`
}

// phonesForLIDs answers, from whatsmeow's own store, which phone number each LID stands
// for. Only known pairs come back. Swift asks about the chats and senders it stored
// under a LID because the mapping was not known yet when their messages arrived, so it
// can file them under the phone number from then on. Nothing goes over the network:
// it works while disconnected, and asks WhatsApp nothing about anyone.
func (b *bridge) phonesForLIDs(args lidsArgs) (any, error) {
	acct, err := b.lookup(args.Account)
	if err != nil {
		return nil, err
	}
	ctx := context.Background()
	out := []map[string]string{}
	for _, raw := range args.LIDs {
		lid, err := types.ParseJID(raw)
		if err != nil || lid.Server != types.HiddenUserServer {
			return nil, fail("invalid_argument", "%q is not a LID", raw)
		}
		pn, err := acct.client.Store.LIDs.GetPNForLID(ctx, lid.ToNonAD())
		if err != nil {
			return nil, fail("database", "could not read the LID map: %v", err)
		}
		if !pn.IsEmpty() {
			out = append(out, map[string]string{"lid": lid.ToNonAD().String(), "phone": pn.ToNonAD().String()})
		}
	}
	return out, nil
}

// MARK: - Sending

// replyRef identifies the message being quoted. Swift supplies the text it has stored so
// the quote renders on the recipient's side without them needing the original.
type replyRef struct {
	ID     string `json:"id"`
	Sender string `json:"sender"` // the original sender's JID, as received
	Text   string `json:"text"`
}

func (r *replyRef) contextInfo() *waE2E.ContextInfo {
	if r == nil || r.ID == "" {
		return nil
	}
	ci := &waE2E.ContextInfo{
		StanzaID:      proto.String(r.ID),
		QuotedMessage: &waE2E.Message{Conversation: proto.String(r.Text)},
	}
	if r.Sender != "" {
		ci.Participant = proto.String(r.Sender)
	}
	return ci
}

type sendResult struct {
	Account   string   `json:"account"`
	Chat      string   `json:"chat"`
	ID        string   `json:"id"`
	Timestamp int64    `json:"timestamp"`
	Message   *message `json:"message,omitempty"`
}

// sent records an outgoing message the way an incoming one would be: whatsmeow does not
// echo a client's own sends back as events, so without this the store would never learn
// of them and a reader would see only half of every conversation.
func (b *bridge) sent(acct *account, to types.JID, resp whatsmeow.SendResponse, msg *waE2E.Message) sendResult {
	own := acct.client.Store.ID.ToNonAD()
	m := &message{
		ID: resp.ID, Chat: to.String(), Sender: own.String(), FromMe: true,
		IsGroup: to.Server == types.GroupServer, Timestamp: resp.Timestamp.Unix(),
	}
	if fillContent(m, msg) {
		b.emit(messagesEvent{Type: "messages", Account: acct.id(), Source: "sent", Messages: []*message{m}})
	} else {
		m = nil
	}
	return sendResult{Account: acct.id(), Chat: to.String(), ID: resp.ID, Timestamp: resp.Timestamp.Unix(), Message: m}
}

type sendTextArgs struct {
	Account string    `json:"account"`
	To      string    `json:"to"`
	Text    string    `json:"text"`
	ReplyTo *replyRef `json:"replyTo"`
}

func (b *bridge) sendText(args sendTextArgs) (any, error) {
	if strings.TrimSpace(args.Text) == "" {
		return nil, fail("invalid_argument", "the message text is empty")
	}
	acct, err := b.connected(args.Account)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), networkTimeout)
	defer cancel()
	to, err := resolveRecipient(ctx, acct.client, args.To)
	if err != nil {
		return nil, err
	}

	msg := &waE2E.Message{}
	if ci := args.ReplyTo.contextInfo(); ci != nil {
		msg.ExtendedTextMessage = &waE2E.ExtendedTextMessage{Text: proto.String(args.Text), ContextInfo: ci}
	} else {
		msg.Conversation = proto.String(args.Text)
	}
	resp, err := acct.client.SendMessage(ctx, to, msg)
	if err != nil {
		return nil, fail("send_failed", "WhatsApp did not accept the message: %v", err)
	}
	return b.sent(acct, to, resp, msg), nil
}

type sendMediaArgs struct {
	Account   string    `json:"account"`
	To        string    `json:"to"`
	Path      string    `json:"path"`
	Kind      string    `json:"kind"` // image, video, audio, voice, document
	MimeType  string    `json:"mimeType"`
	FileName  string    `json:"fileName"`
	Caption   string    `json:"caption"`
	Seconds   uint32    `json:"seconds"`
	Width     uint32    `json:"width"`
	Height    uint32    `json:"height"`
	Thumbnail []byte    `json:"thumbnail"` // small JPEG, shown before the media downloads
	ReplyTo   *replyRef `json:"replyTo"`
}

func (b *bridge) sendMedia(args sendMediaArgs) (any, error) {
	acct, err := b.connected(args.Account)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(args.Path)
	if err != nil {
		return nil, fail("file_unreadable", "could not read %s: %v", args.Path, err)
	}
	if args.MimeType == "" {
		args.MimeType = "application/octet-stream"
	}
	if args.FileName == "" {
		args.FileName = filepath.Base(args.Path)
	}

	var mediaType whatsmeow.MediaType
	switch args.Kind {
	case "image":
		mediaType = whatsmeow.MediaImage
	case "video":
		mediaType = whatsmeow.MediaVideo
	case "audio", "voice":
		mediaType = whatsmeow.MediaAudio
		if args.Caption != "" {
			return nil, fail("invalid_argument", "WhatsApp audio messages can't carry a caption — send the text separately")
		}
	case "document":
		mediaType = whatsmeow.MediaDocument
	default:
		return nil, fail("invalid_argument", "unsupported media kind %q", args.Kind)
	}

	ctx, cancel := context.WithTimeout(context.Background(), uploadTimeout)
	defer cancel()
	to, err := resolveRecipient(ctx, acct.client, args.To)
	if err != nil {
		return nil, err
	}
	up, err := acct.client.Upload(ctx, data, mediaType)
	if err != nil {
		return nil, fail("upload_failed", "could not upload %s: %v", args.FileName, err)
	}

	ci := args.ReplyTo.contextInfo()
	caption := optional(args.Caption)
	msg := &waE2E.Message{}
	switch args.Kind {
	case "image":
		msg.ImageMessage = &waE2E.ImageMessage{
			Caption: caption, Mimetype: proto.String(args.MimeType),
			URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath),
			MediaKey: up.MediaKey, FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256,
			FileLength: proto.Uint64(up.FileLength), Width: optionalU32(args.Width), Height: optionalU32(args.Height),
			JPEGThumbnail: args.Thumbnail, ContextInfo: ci,
		}
	case "video":
		msg.VideoMessage = &waE2E.VideoMessage{
			Caption: caption, Mimetype: proto.String(args.MimeType),
			URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath),
			MediaKey: up.MediaKey, FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256,
			FileLength: proto.Uint64(up.FileLength), Seconds: optionalU32(args.Seconds),
			Width: optionalU32(args.Width), Height: optionalU32(args.Height),
			JPEGThumbnail: args.Thumbnail, ContextInfo: ci,
		}
	case "audio", "voice":
		msg.AudioMessage = &waE2E.AudioMessage{
			Mimetype: proto.String(args.MimeType),
			URL:      proto.String(up.URL), DirectPath: proto.String(up.DirectPath),
			MediaKey: up.MediaKey, FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256,
			FileLength: proto.Uint64(up.FileLength), Seconds: optionalU32(args.Seconds),
			PTT: proto.Bool(args.Kind == "voice"), ContextInfo: ci,
		}
	case "document":
		msg.DocumentMessage = &waE2E.DocumentMessage{
			Caption: caption, Mimetype: proto.String(args.MimeType),
			FileName: proto.String(args.FileName), Title: proto.String(args.FileName),
			URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath),
			MediaKey: up.MediaKey, FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256,
			FileLength: proto.Uint64(up.FileLength), JPEGThumbnail: args.Thumbnail, ContextInfo: ci,
		}
	}

	resp, err := acct.client.SendMessage(ctx, to, msg)
	if err != nil {
		return nil, fail("send_failed", "WhatsApp did not accept the message: %v", err)
	}
	return b.sent(acct, to, resp, msg), nil
}

type reactArgs struct {
	Account string `json:"account"`
	Chat    string `json:"chat"`   // as received (rawChat when there is one)
	Sender  string `json:"sender"` // the reacted-to message's sender, as received
	FromMe  bool   `json:"fromMe"`
	ID      string `json:"id"`
	Emoji   string `json:"emoji"` // "" removes a reaction
}

func (b *bridge) react(args reactArgs) (any, error) {
	acct, err := b.connected(args.Account)
	if err != nil {
		return nil, err
	}
	chat, err := types.ParseJID(args.Chat)
	if err != nil {
		return nil, fail("invalid_argument", "invalid chat %q", args.Chat)
	}
	sender := acct.client.Store.ID.ToNonAD()
	if !args.FromMe {
		if sender, err = types.ParseJID(args.Sender); err != nil {
			return nil, fail("invalid_argument", "invalid sender %q", args.Sender)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), networkTimeout)
	defer cancel()
	msg := acct.client.BuildReaction(chat, sender, args.ID, args.Emoji)
	resp, err := acct.client.SendMessage(ctx, chat, msg)
	if err != nil {
		return nil, fail("send_failed", "WhatsApp did not accept the reaction: %v", err)
	}
	return b.sent(acct, chat, resp, msg), nil
}

type markReadArgs struct {
	Account  string `json:"account"`
	Chat     string `json:"chat"` // as received
	Messages []struct {
		ID     string `json:"id"`
		Sender string `json:"sender"` // as received
	} `json:"messages"`
}

// markRead sends read receipts — blue ticks on the sender's side. WhatsApp takes one
// receipt per sender, so a group's messages are grouped before sending.
func (b *bridge) markRead(args markReadArgs) (any, error) {
	acct, err := b.connected(args.Account)
	if err != nil {
		return nil, err
	}
	chat, err := types.ParseJID(args.Chat)
	if err != nil {
		return nil, fail("invalid_argument", "invalid chat %q", args.Chat)
	}
	bySender := map[string][]types.MessageID{}
	for _, m := range args.Messages {
		bySender[m.Sender] = append(bySender[m.Sender], m.ID)
	}
	ctx, cancel := context.WithTimeout(context.Background(), networkTimeout)
	defer cancel()
	now := time.Now()
	for senderString, ids := range bySender {
		sender := chat
		if senderString != "" {
			if sender, err = types.ParseJID(senderString); err != nil {
				return nil, fail("invalid_argument", "invalid sender %q", senderString)
			}
		}
		if err := acct.client.MarkRead(ctx, ids, now, chat, sender); err != nil {
			return nil, fail("send_failed", "could not send read receipts: %v", err)
		}
	}
	return nil, nil
}

// MARK: - Media download

type downloadArgs struct {
	Account string `json:"account"`
	Raw     []byte `json:"raw"`  // media.raw from the message event
	Path    string `json:"path"` // destination, already approved by Swift's DownloadConfig
}

// download decrypts an attachment straight to disk. The bytes never go back across the
// ABI — Swift (and the MCP client) only ever see the path.
func (b *bridge) download(args downloadArgs) (any, error) {
	acct, err := b.connected(args.Account)
	if err != nil {
		return nil, err
	}
	var msg waE2E.Message
	if err := proto.Unmarshal(args.Raw, &msg); err != nil {
		return nil, fail("invalid_argument", "the stored media reference is unreadable: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), uploadTimeout)
	defer cancel()
	data, err := acct.client.DownloadAny(ctx, &msg)
	if err != nil {
		if errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith404) || errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith410) {
			return nil, fail("media_expired",
				"WhatsApp no longer has this file on its servers. Open the message on the phone to make it available again.")
		}
		return nil, fail("download_failed", "could not download the media: %v", err)
	}

	if err := os.MkdirAll(filepath.Dir(args.Path), 0o755); err != nil {
		return nil, fail("write_failed", "could not create %s: %v", filepath.Dir(args.Path), err)
	}
	tmp := args.Path + ".part"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return nil, fail("write_failed", "could not write %s: %v", args.Path, err)
	}
	if err := os.Rename(tmp, args.Path); err != nil {
		_ = os.Remove(tmp)
		return nil, fail("write_failed", "could not write %s: %v", args.Path, err)
	}
	return map[string]any{"path": args.Path, "size": len(data)}, nil
}

// MARK: - Contacts and groups

type contactEntry struct {
	JID          string `json:"jid"`
	Phone        string `json:"phone,omitempty"`
	FirstName    string `json:"firstName,omitempty"`
	FullName     string `json:"fullName,omitempty"`
	PushName     string `json:"pushName,omitempty"`
	BusinessName string `json:"businessName,omitempty"`
}

// contacts returns whatsmeow's contact store — names from the phone's address book and
// the push names people chose for themselves — keyed by phone-number JID wherever the
// LID mapping is known, merged when both forms are present.
func (b *bridge) contacts(args accountArgs) (any, error) {
	acct, err := b.lookup(args.Account)
	if err != nil {
		return nil, err
	}
	ctx := context.Background()
	all, err := acct.client.Store.Contacts.GetAllContacts(ctx)
	if err != nil {
		return nil, fail("database", "could not read contacts: %v", err)
	}
	merged := map[string]*contactEntry{}
	for jid, info := range all {
		key := pnFor(ctx, acct.client, jid, types.EmptyJID)
		entry, ok := merged[key.String()]
		if !ok {
			entry = &contactEntry{JID: key.String()}
			if key.Server == types.DefaultUserServer {
				entry.Phone = "+" + key.User
			}
			merged[key.String()] = entry
		}
		entry.FirstName = firstNonEmpty(entry.FirstName, info.FirstName)
		entry.FullName = firstNonEmpty(entry.FullName, info.FullName)
		entry.PushName = firstNonEmpty(entry.PushName, info.PushName)
		entry.BusinessName = firstNonEmpty(entry.BusinessName, info.BusinessName)
	}
	out := make([]*contactEntry, 0, len(merged))
	for _, e := range merged {
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].JID < out[j].JID })
	return out, nil
}

type participant struct {
	JID          string `json:"jid"`
	Phone        string `json:"phone,omitempty"`
	LID          string `json:"lid,omitempty"`
	IsAdmin      bool   `json:"isAdmin"`
	IsSuperAdmin bool   `json:"isSuperAdmin"`
	DisplayName  string `json:"displayName,omitempty"`
}

type groupEntry struct {
	JID              string        `json:"jid"`
	Name             string        `json:"name"`
	Topic            string        `json:"topic,omitempty"`
	Created          int64         `json:"created,omitempty"`
	Owner            string        `json:"owner,omitempty"`
	IsAnnounce       bool          `json:"isAnnounce"`
	IsLocked         bool          `json:"isLocked"`
	ParticipantCount int           `json:"participantCount"`
	Participants     []participant `json:"participants,omitempty"`
}

func describeGroup(g *types.GroupInfo, withParticipants bool) groupEntry {
	entry := groupEntry{
		JID: g.JID.String(), Name: g.Name, Topic: g.Topic,
		IsAnnounce: g.IsAnnounce, IsLocked: g.IsLocked,
		ParticipantCount: len(g.Participants),
	}
	if !g.GroupCreated.IsZero() {
		entry.Created = g.GroupCreated.Unix()
	}
	if !g.OwnerPN.IsEmpty() {
		entry.Owner = g.OwnerPN.String()
	} else if !g.OwnerJID.IsEmpty() {
		entry.Owner = g.OwnerJID.String()
	}
	if withParticipants {
		for _, p := range g.Participants {
			jid := p.JID
			if !p.PhoneNumber.IsEmpty() {
				jid = p.PhoneNumber
			}
			out := participant{JID: jid.String(), IsAdmin: p.IsAdmin, IsSuperAdmin: p.IsSuperAdmin, DisplayName: p.DisplayName}
			if !p.PhoneNumber.IsEmpty() {
				out.Phone = "+" + p.PhoneNumber.User
			}
			if !p.LID.IsEmpty() {
				out.LID = p.LID.String()
			}
			entry.Participants = append(entry.Participants, out)
		}
	}
	return entry
}

func (b *bridge) groups(args accountArgs) (any, error) {
	acct, err := b.connected(args.Account)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), networkTimeout)
	defer cancel()
	groups, err := acct.client.GetJoinedGroups(ctx)
	if err != nil {
		return nil, fail("request_failed", "could not list groups: %v", err)
	}
	out := make([]groupEntry, 0, len(groups))
	for _, g := range groups {
		out = append(out, describeGroup(g, false))
	}
	return out, nil
}

type groupInfoArgs struct {
	Account string `json:"account"`
	JID     string `json:"jid"`
}

func (b *bridge) groupInfo(args groupInfoArgs) (any, error) {
	acct, err := b.connected(args.Account)
	if err != nil {
		return nil, err
	}
	jid, err := types.ParseJID(args.JID)
	if err != nil || jid.Server != types.GroupServer {
		return nil, fail("invalid_argument", "%q is not a group JID (they end in @g.us)", args.JID)
	}
	ctx, cancel := context.WithTimeout(context.Background(), networkTimeout)
	defer cancel()
	info, err := acct.client.GetGroupInfo(ctx, jid)
	if err != nil {
		return nil, fail("request_failed", "could not read the group: %v", err)
	}
	return describeGroup(info, true), nil
}

// MARK: - Small helpers

func optional(s string) *string {
	if s == "" {
		return nil
	}
	return proto.String(s)
}

func optionalU32(v uint32) *uint32 {
	if v == 0 {
		return nil
	}
	return proto.Uint32(v)
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}
