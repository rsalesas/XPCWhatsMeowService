package main

import (
	"context"
	"fmt"
	"strings"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

// message is the normalised form of every WhatsApp message Swift sees, live or from
// history. It is flat on purpose: Swift stores it as one row.
type message struct {
	ID        string `json:"id"`
	Chat      string `json:"chat"`              // phone-number JID where known, else as received
	Sender    string `json:"sender"`            // likewise
	RawChat   string `json:"rawChat,omitempty"` // the JID as received, when it differs (LID)
	RawSender string `json:"rawSender,omitempty"`
	PushName  string `json:"pushName,omitempty"`
	FromMe    bool   `json:"fromMe"`
	IsGroup   bool   `json:"isGroup"`
	Timestamp int64  `json:"timestamp"` // unix seconds

	// text, image, video, gif, audio, voice, document, sticker, location, contact, poll,
	// and three that modify another message rather than standing alone: reaction, edit,
	// revoke — each names its target in TargetID.
	Kind     string `json:"kind"`
	Text     string `json:"text,omitempty"`
	QuotedID string `json:"quotedId,omitempty"`
	TargetID string `json:"targetId,omitempty"`

	Media *media `json:"media,omitempty"`
}

// media describes an attachment. Raw is the marshalled waE2E.Message holding just the
// media sub-message — everything DownloadAny needs later, including the decryption key.
// Swift keeps it opaque and hands it back to "download".
type media struct {
	MimeType string `json:"mimeType,omitempty"`
	FileName string `json:"fileName,omitempty"`
	FileSize uint64 `json:"fileSize,omitempty"`
	Seconds  uint32 `json:"seconds,omitempty"`
	Width    uint32 `json:"width,omitempty"`
	Height   uint32 `json:"height,omitempty"`
	Raw      []byte `json:"raw"`
}

type messagesEvent struct {
	Type     string     `json:"type"`
	Account  string     `json:"account"`
	Source   string     `json:"source"` // live, history, sent
	Messages []*message `json:"messages"`
}

type chatInfo struct {
	JID         string `json:"jid"`
	Name        string `json:"name,omitempty"`
	IsGroup     bool   `json:"isGroup"`
	UnreadCount uint32 `json:"unreadCount,omitempty"`
	Archived    bool   `json:"archived,omitempty"`
}

type chatsEvent struct {
	Type    string     `json:"type"`
	Account string     `json:"account"`
	Chats   []chatInfo `json:"chats"`
}

// MARK: - Conversion

// convertMessage returns nil for traffic a reader has no use for: status updates
// (stories), channel posts, key distribution and other protocol housekeeping.
func convertMessage(ctx context.Context, client *whatsmeow.Client, evt *events.Message) *message {
	info := evt.Info
	if info.Chat.Server == types.BroadcastServer && info.Chat.User == "status" {
		return nil
	}
	if info.Chat.Server == types.NewsletterServer {
		return nil
	}

	chatAlt := info.SenderAlt
	if info.IsFromMe {
		chatAlt = info.RecipientAlt
	}
	chat := info.Chat
	if !info.IsGroup {
		chat = pnFor(ctx, client, info.Chat, chatAlt)
	}
	sender := pnFor(ctx, client, info.Sender, info.SenderAlt)

	m := &message{
		ID:        info.ID,
		Chat:      chat.String(),
		Sender:    sender.String(),
		PushName:  info.PushName,
		FromMe:    info.IsFromMe,
		IsGroup:   info.IsGroup,
		Timestamp: info.Timestamp.Unix(),
	}
	if raw := info.Chat.ToNonAD().String(); raw != m.Chat {
		m.RawChat = raw
	}
	if raw := info.Sender.ToNonAD().String(); raw != m.Sender {
		m.RawSender = raw
	}
	if !fillContent(m, evt.Message) {
		return nil
	}
	return m
}

// fillContent reads the one meaningful payload of a (already unwrapped) message.
func fillContent(m *message, msg *waE2E.Message) bool {
	if msg == nil {
		return false
	}
	switch {
	case msg.GetProtocolMessage() != nil:
		pm := msg.GetProtocolMessage()
		switch pm.GetType() {
		case waE2E.ProtocolMessage_REVOKE:
			m.Kind, m.TargetID = "revoke", pm.GetKey().GetID()
		case waE2E.ProtocolMessage_MESSAGE_EDIT:
			m.Kind, m.TargetID = "edit", pm.GetKey().GetID()
			m.Text = plainText(pm.GetEditedMessage())
		default:
			return false
		}

	case msg.GetReactionMessage() != nil:
		r := msg.GetReactionMessage()
		m.Kind, m.TargetID, m.Text = "reaction", r.GetKey().GetID(), r.GetText()

	case msg.GetConversation() != "":
		m.Kind, m.Text = "text", msg.GetConversation()

	case msg.GetExtendedTextMessage() != nil:
		t := msg.GetExtendedTextMessage()
		m.Kind, m.Text = "text", t.GetText()
		m.QuotedID = t.GetContextInfo().GetStanzaID()

	case msg.GetImageMessage() != nil:
		img := msg.GetImageMessage()
		m.Kind, m.Text = "image", img.GetCaption()
		m.QuotedID = img.GetContextInfo().GetStanzaID()
		m.Media = &media{MimeType: img.GetMimetype(), FileSize: img.GetFileLength(),
			Width: img.GetWidth(), Height: img.GetHeight(),
			Raw: marshal(&waE2E.Message{ImageMessage: img})}

	case msg.GetVideoMessage() != nil:
		v := msg.GetVideoMessage()
		m.Kind, m.Text = "video", v.GetCaption()
		if v.GetGifPlayback() {
			m.Kind = "gif"
		}
		m.QuotedID = v.GetContextInfo().GetStanzaID()
		m.Media = &media{MimeType: v.GetMimetype(), FileSize: v.GetFileLength(), Seconds: v.GetSeconds(),
			Width: v.GetWidth(), Height: v.GetHeight(),
			Raw: marshal(&waE2E.Message{VideoMessage: v})}

	case msg.GetAudioMessage() != nil:
		a := msg.GetAudioMessage()
		m.Kind = "audio"
		if a.GetPTT() {
			m.Kind = "voice"
		}
		m.QuotedID = a.GetContextInfo().GetStanzaID()
		m.Media = &media{MimeType: a.GetMimetype(), FileSize: a.GetFileLength(), Seconds: a.GetSeconds(),
			Raw: marshal(&waE2E.Message{AudioMessage: a})}

	case msg.GetDocumentMessage() != nil:
		d := msg.GetDocumentMessage()
		m.Kind, m.Text = "document", d.GetCaption()
		m.QuotedID = d.GetContextInfo().GetStanzaID()
		name := d.GetFileName()
		if name == "" {
			name = d.GetTitle()
		}
		m.Media = &media{MimeType: d.GetMimetype(), FileName: name, FileSize: d.GetFileLength(),
			Raw: marshal(&waE2E.Message{DocumentMessage: d})}

	case msg.GetStickerMessage() != nil:
		s := msg.GetStickerMessage()
		m.Kind = "sticker"
		m.QuotedID = s.GetContextInfo().GetStanzaID()
		m.Media = &media{MimeType: s.GetMimetype(), FileSize: s.GetFileLength(),
			Width: s.GetWidth(), Height: s.GetHeight(),
			Raw: marshal(&waE2E.Message{StickerMessage: s})}

	case msg.GetLocationMessage() != nil:
		l := msg.GetLocationMessage()
		m.Kind = "location"
		m.Text = describePlace(l.GetName(), l.GetAddress(), l.GetDegreesLatitude(), l.GetDegreesLongitude())
	case msg.GetLiveLocationMessage() != nil:
		l := msg.GetLiveLocationMessage()
		m.Kind = "location"
		m.Text = describePlace("Live location", l.GetCaption(), l.GetDegreesLatitude(), l.GetDegreesLongitude())

	case msg.GetContactMessage() != nil:
		c := msg.GetContactMessage()
		m.Kind, m.Text = "contact", c.GetDisplayName()+"\n"+c.GetVcard()
	case msg.GetContactsArrayMessage() != nil:
		names := []string{}
		for _, c := range msg.GetContactsArrayMessage().GetContacts() {
			names = append(names, c.GetDisplayName())
		}
		m.Kind, m.Text = "contact", strings.Join(names, ", ")

	case pollOf(msg) != nil:
		p := pollOf(msg)
		options := []string{}
		for _, o := range p.GetOptions() {
			options = append(options, "• "+o.GetOptionName())
		}
		m.Kind, m.Text = "poll", p.GetName()+"\n"+strings.Join(options, "\n")
		m.QuotedID = p.GetContextInfo().GetStanzaID()

	default:
		return false
	}
	return true
}

func pollOf(msg *waE2E.Message) *waE2E.PollCreationMessage {
	if p := msg.GetPollCreationMessage(); p != nil {
		return p
	}
	if p := msg.GetPollCreationMessageV2(); p != nil {
		return p
	}
	return msg.GetPollCreationMessageV3()
}

// plainText is the readable text of a message used as an edit's new content.
func plainText(msg *waE2E.Message) string {
	switch {
	case msg == nil:
		return ""
	case msg.GetConversation() != "":
		return msg.GetConversation()
	case msg.GetExtendedTextMessage() != nil:
		return msg.GetExtendedTextMessage().GetText()
	case msg.GetImageMessage() != nil:
		return msg.GetImageMessage().GetCaption()
	case msg.GetVideoMessage() != nil:
		return msg.GetVideoMessage().GetCaption()
	case msg.GetDocumentMessage() != nil:
		return msg.GetDocumentMessage().GetCaption()
	}
	return ""
}

func describePlace(name, address string, lat, lon float64) string {
	parts := []string{}
	for _, s := range []string{name, address} {
		if s != "" {
			parts = append(parts, s)
		}
	}
	parts = append(parts, fmt.Sprintf("%.6f,%.6f", lat, lon))
	return strings.Join(parts, " — ")
}

func marshal(msg *waE2E.Message) []byte {
	data, err := proto.Marshal(msg)
	if err != nil {
		return nil
	}
	return data
}

// MARK: - History sync

// handleHistorySync forwards one blob of history, a conversation at a time so no single
// event is unboundedly large. Chats go last, carrying names and unread counts: by then
// Swift has the messages those counts refer to.
func (b *bridge) handleHistorySync(ctx context.Context, acct *account, evt *events.HistorySync) {
	id := acct.id()
	data := evt.Data
	chats := []chatInfo{}

	for _, conv := range data.GetConversations() {
		chatJID, err := types.ParseJID(conv.GetID())
		if err != nil || chatJID.Server == types.NewsletterServer ||
			(chatJID.Server == types.BroadcastServer && chatJID.User == "status") {
			continue
		}
		isGroup := chatJID.Server == types.GroupServer
		normalized := chatJID
		if !isGroup {
			normalized = pnFor(ctx, acct.client, chatJID, types.EmptyJID)
		}
		name := conv.GetName()
		if name == "" {
			name = conv.GetDisplayName()
		}
		chats = append(chats, chatInfo{
			JID: normalized.String(), Name: name, IsGroup: isGroup,
			UnreadCount: conv.GetUnreadCount(), Archived: conv.GetArchived(),
		})

		msgs := []*message{}
		for _, hm := range conv.GetMessages() {
			evt, err := acct.client.ParseWebMessage(chatJID, hm.GetMessage())
			if err != nil {
				continue
			}
			if m := convertMessage(ctx, acct.client, evt); m != nil {
				msgs = append(msgs, m)
			}
		}
		if len(msgs) > 0 {
			b.emit(messagesEvent{Type: "messages", Account: id, Source: "history", Messages: msgs})
		}
	}

	if len(chats) > 0 {
		b.emit(chatsEvent{Type: "chats", Account: id, Chats: chats})
	}
	b.emit(map[string]any{
		"type": "history_progress", "account": id,
		"syncType": data.GetSyncType().String(), "progress": data.GetProgress(),
	})
}

// MARK: - Receipts

func (b *bridge) emitReceipt(ctx context.Context, acct *account, evt *events.Receipt) {
	chat := evt.Chat
	if !evt.IsGroup {
		alt := evt.SenderAlt
		if evt.IsFromMe {
			alt = evt.RecipientAlt
		}
		chat = pnFor(ctx, acct.client, evt.Chat, alt)
	}
	b.emit(map[string]any{
		"type": "receipt", "account": acct.id(),
		"chat": chat.String(), "ids": evt.MessageIDs,
		// "" (delivered), read, played — or read-self/played-self when another of the
		// user's own devices read an incoming message.
		"receiptType": string(evt.Type), "fromMe": evt.IsFromMe,
		"timestamp": evt.Timestamp.Unix(),
	})
}
