package main

import (
	"testing"

	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"google.golang.org/protobuf/proto"
)

func fill(t *testing.T, msg *waE2E.Message) (*message, bool) {
	t.Helper()
	m := &message{}
	return m, fillContent(m, msg)
}

func TestTextAndReplies(t *testing.T) {
	m, ok := fill(t, &waE2E.Message{Conversation: proto.String("hello")})
	if !ok || m.Kind != "text" || m.Text != "hello" {
		t.Fatalf("plain text: %+v", m)
	}
	m, ok = fill(t, &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
		Text:        proto.String("yes"),
		ContextInfo: &waE2E.ContextInfo{StanzaID: proto.String("Q1")},
	}})
	if !ok || m.Text != "yes" || m.QuotedID != "Q1" {
		t.Fatalf("reply: %+v", m)
	}
}

func TestModifiersNameTheirTarget(t *testing.T) {
	key := &waCommon.MessageKey{ID: proto.String("T1")}

	m, ok := fill(t, &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{
		Type: waE2E.ProtocolMessage_REVOKE.Enum(), Key: key,
	}})
	if !ok || m.Kind != "revoke" || m.TargetID != "T1" {
		t.Fatalf("revoke: %+v", m)
	}

	m, ok = fill(t, &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{
		Type: waE2E.ProtocolMessage_MESSAGE_EDIT.Enum(), Key: key,
		EditedMessage: &waE2E.Message{Conversation: proto.String("fixed")},
	}})
	if !ok || m.Kind != "edit" || m.TargetID != "T1" || m.Text != "fixed" {
		t.Fatalf("edit: %+v", m)
	}

	m, ok = fill(t, &waE2E.Message{ReactionMessage: &waE2E.ReactionMessage{Key: key, Text: proto.String("👍")}})
	if !ok || m.Kind != "reaction" || m.TargetID != "T1" || m.Text != "👍" {
		t.Fatalf("reaction: %+v", m)
	}
}

func TestHousekeepingIsDropped(t *testing.T) {
	if _, ok := fill(t, &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{
		Type: waE2E.ProtocolMessage_HISTORY_SYNC_NOTIFICATION.Enum(),
	}}); ok {
		t.Fatal("a history-sync notification is not a message")
	}
	if _, ok := fill(t, &waE2E.Message{SenderKeyDistributionMessage: &waE2E.SenderKeyDistributionMessage{}}); ok {
		t.Fatal("key distribution is not a message")
	}
	if _, ok := fill(t, nil); ok {
		t.Fatal("nil is not a message")
	}
}

// The media reference must round-trip exactly: it carries the key download needs.
func TestMediaKeepsADownloadableReference(t *testing.T) {
	doc := &waE2E.DocumentMessage{
		FileName: proto.String("cv.pdf"), Mimetype: proto.String("application/pdf"),
		FileLength: proto.Uint64(42), MediaKey: []byte{1, 2, 3}, Caption: proto.String("my cv"),
	}
	m, ok := fill(t, &waE2E.Message{DocumentMessage: doc})
	if !ok || m.Kind != "document" || m.Text != "my cv" || m.Media == nil {
		t.Fatalf("document: %+v", m)
	}
	if m.Media.FileName != "cv.pdf" || m.Media.FileSize != 42 || m.Media.MimeType != "application/pdf" {
		t.Fatalf("media fields: %+v", m.Media)
	}
	var back waE2E.Message
	if err := proto.Unmarshal(m.Media.Raw, &back); err != nil {
		t.Fatal(err)
	}
	if string(back.GetDocumentMessage().GetMediaKey()) != string([]byte{1, 2, 3}) {
		t.Fatal("media key lost")
	}
}

func TestVoiceGifAndPoll(t *testing.T) {
	m, _ := fill(t, &waE2E.Message{AudioMessage: &waE2E.AudioMessage{PTT: proto.Bool(true), Seconds: proto.Uint32(7)}})
	if m.Kind != "voice" || m.Media.Seconds != 7 {
		t.Fatalf("voice note: %+v", m)
	}
	m, _ = fill(t, &waE2E.Message{VideoMessage: &waE2E.VideoMessage{GifPlayback: proto.Bool(true)}})
	if m.Kind != "gif" {
		t.Fatalf("gif: %+v", m)
	}
	m, _ = fill(t, &waE2E.Message{PollCreationMessageV3: &waE2E.PollCreationMessage{
		Name:    proto.String("Lunch?"),
		Options: []*waE2E.PollCreationMessage_Option{{OptionName: proto.String("Yes")}, {OptionName: proto.String("No")}},
	}})
	if m.Kind != "poll" || m.Text != "Lunch?\n• Yes\n• No" {
		t.Fatalf("poll: %q", m.Text)
	}
}

func TestLocations(t *testing.T) {
	m, _ := fill(t, &waE2E.Message{LocationMessage: &waE2E.LocationMessage{
		Name: proto.String("Office"), DegreesLatitude: proto.Float64(51.5), DegreesLongitude: proto.Float64(-0.12),
	}})
	if m.Kind != "location" || m.Text != "Office — 51.500000,-0.120000" {
		t.Fatalf("location: %q", m.Text)
	}
}

func TestDigits(t *testing.T) {
	for in, want := range map[string]string{
		"+1 (555) 010-0000": "15550100000",
		"15550100000":       "15550100000",
		"":                  "",
		"٣٤٥":               "", // only ASCII digits identify an account
	} {
		if got := digits(in); got != want {
			t.Errorf("digits(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestHistoryMappingsFromTableAndConversations(t *testing.T) {
	data := &waHistorySync.HistorySync{
		PhoneNumberToLidMappings: []*waHistorySync.PhoneNumberToLIDMapping{
			{LidJID: proto.String("111@lid"), PnJID: proto.String("15550001111@s.whatsapp.net")},
			{LidJID: proto.String("not-a-jid@"), PnJID: proto.String("x")},
		},
		Conversations: []*waHistorySync.Conversation{
			// A LID chat naming its own number, in the legacy c.us form.
			{ID: proto.String("222@lid"), PnJID: proto.String("15550002222@c.us")},
			// Repeats the table's pair: reported once.
			{ID: proto.String("15550001111@s.whatsapp.net"), LidJID: proto.String("111@lid"), PnJID: proto.String("15550001111@s.whatsapp.net")},
			// A group, and a LID chat with no number: nothing to learn.
			{ID: proto.String("123-456@g.us")},
			{ID: proto.String("333@lid")},
		},
	}
	got := map[string]string{}
	for _, m := range historyMappings(data) {
		got[m.LID.String()] = m.PN.String()
	}
	want := map[string]string{
		"111@lid": "15550001111@s.whatsapp.net",
		"222@lid": "15550002222@s.whatsapp.net",
	}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for lid, pn := range want {
		if got[lid] != pn {
			t.Errorf("%s → %q, want %q", lid, got[lid], pn)
		}
	}
}
