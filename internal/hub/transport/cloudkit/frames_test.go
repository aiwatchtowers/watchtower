package cloudkit_test

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"os"
	"path/filepath"
	"testing"

	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"

	"watchtower/internal/hub/transport/cloudkit"
	pb "watchtower/internal/hub/transport/cloudkit/bridgepb"
)

var update = flag.Bool("update", false, "rewrite testdata/frames.json")

const fixturePath = "testdata/frames.json"

// fixtureCase is one frames.json case: the message type, its protojson form
// (proto field names) and its bytes in hex. The Swift bridge reads the same
// file (BridgeFramesFixtureTests): every case decodes and re-encodes to the
// same bytes.
type fixtureCase struct {
	Name    string          `json:"name"`
	Message string          `json:"message"`
	JSON    json.RawMessage `json:"json"`
	Hex     string          `json:"hex"`
}

type fixture struct {
	Note  string        `json:"note"`
	Cases []fixtureCase `json:"cases"`
}

const fixtureNote = "Bridge protocol v1 frames (bridge.proto). hex is the message bytes without the u32 length prefix; " +
	"fields in field-number order, defaults omitted. Regenerate: go test ./internal/hub/transport/cloudkit -run TestFramesFixture -update"

// fixtureCases are the pinned frames: every request op and every answer
// kind, with edge values (a tag_seq above 2^63, empty messages, an absent
// conflict next to a present one, a signal's empty envelope, non-ASCII).
func fixtureCases() []struct {
	name string
	msg  proto.Message
} {
	hub := "8C1D2E3F-0000-4000-8000-00000000ACME"
	data, relay := cloudkit.DataZoneName(hub), cloudkit.RelayZoneName(hub)
	env := []byte{0x57, 0x54, 0x45, 0x31, 0x00, 0x01, 0x00, 0xff, 0x80}
	big := uint64(1)<<63 + 12345
	gen := "5f1c0a9e2b7d4c18"
	type c = struct {
		name string
		msg  proto.Message
	}
	return []c{
		{"hello", &pb.Request{Id: 1, Op: &pb.Request_Hello{Hello: &pb.Hello{Version: 1, HubId: hub}}}},
		{"save", &pb.Request{Id: 2, Op: &pb.Request_Save{Save: &pb.Save{Items: []*pb.SaveItem{
			{Zone: data, Name: "k1a2b3", Envelope: env},
			{Zone: relay, Name: "a-DEVICE-7", Envelope: env, Expect: &pb.Expect{Mode: pb.ExpectMode_EXPECT_ABSENT}},
			{Zone: data, Name: "t9x8", Envelope: env, AssetPath: "/hub/assets/transcripts/7.asset", Expect: &pb.Expect{Mode: pb.ExpectMode_EXPECT_SEQ, TagSeq: big, Generation: gen}},
			{Zone: data, Name: "sig-k1a2b3"},
		}}}}},
		{"delete", &pb.Request{Id: 3, Op: &pb.Request_Delete{Delete: &pb.Delete{Zone: relay, Items: []*pb.DeleteItem{
			{Name: "c-1"}, {Name: "a-DEVICE-7", Expect: &pb.Expect{Mode: pb.ExpectMode_EXPECT_SEQ, TagSeq: 300, Generation: gen}},
		}}}}},
		{"changes", &pb.Request{Id: 4, Op: &pb.Request_Changes{Changes: &pb.Changes{Zone: relay, Since: 150, Generation: gen}}}},
		{"changes_from_start", &pb.Request{Id: 5, Op: &pb.Request_Changes{Changes: &pb.Changes{Zone: data}}}},
		{"download", &pb.Request{Id: 6, Op: &pb.Request_Download{Download: &pb.Download{Zone: relay, AssetId: "asset-1", Dst: "/hub/downloads/ab12.part"}}}},
		{"account_status", &pb.Request{Id: 7, Op: &pb.Request_AccountStatus{AccountStatus: &pb.AccountStatus{}}}},
		{"ensure_shares", &pb.Request{Id: 8, Op: &pb.Request_EnsureShares{EnsureShares: &pb.EnsureShares{}}}},
		{"set_public_link_open", &pb.Request{Id: 9, Op: &pb.Request_SetPublicLink{SetPublicLink: &pb.SetPublicLink{Open: true}}}},
		{"set_public_link_closed", &pb.Request{Id: 10, Op: &pb.Request_SetPublicLink{SetPublicLink: &pb.SetPublicLink{}}}},
		{"participants", &pb.Request{Id: 11, Op: &pb.Request_Participants{Participants: &pb.Participants{Zone: data}}}},
		{"remove_participants", &pb.Request{Id: 12, Op: &pb.Request_RemoveParticipants{RemoveParticipants: &pb.RemoveParticipants{
			Zone: relay, UserRecordNames: []string{"_user-a", "_user-é"},
		}}}},
		{"owner_user", &pb.Request{Id: 13, Op: &pb.Request_OwnerUser{OwnerUser: &pb.OwnerUser{}}}},
		{"hello_ok", &pb.Response{Id: 1, Result: &pb.Response_Hello{Hello: &pb.HelloOk{Version: 1, Generation: gen}}}},
		{"outcomes", &pb.Response{Id: 2, Result: &pb.Response_Outcomes{Outcomes: &pb.Outcomes{Items: []*pb.Outcome{
			{Saved: true, TagSeq: big},
			{Conflict: &pb.Record{Name: "a-DEVICE-7", Envelope: env, TagSeq: 77, ServerAtMs: 1_800_000_000_123}},
			{},
			{RefusedClass: "record_too_large"},
		}}}}},
		{"batch", &pb.Response{Id: 4, Result: &pb.Response_Batch{Batch: &pb.Batch{
			Changed: []*pb.Record{
				{Name: "a-DEVICE-8", Envelope: env, TagSeq: big, ServerAtMs: 1_800_000_000_999},
				{Name: "recupload-u1", Envelope: env, TagSeq: 5, ServerAtMs: 1_800_000_001_000, AssetId: "asset-1"},
			},
			Deleted: []string{"c-1", "c-2"}, NewSeq: 152, More: true, Generation: gen,
		}}}},
		{"batch_creators", &pb.Response{Id: 14, Result: &pb.Response_Batch{Batch: &pb.Batch{
			Changed: []*pb.Record{
				{Name: "hello-DEVICE-9", Envelope: env, TagSeq: 9, ServerAtMs: 1_800_000_002_000, Creator: "_user-é"},
				{Name: "device-DEVICE-9", Envelope: env, TagSeq: big, Creator: "__defaultOwner__"},
				{Name: "a-DEVICE-9-1", Envelope: env, TagSeq: 10},
			},
			NewSeq: 3, Generation: gen,
		}}}},
		{"batch_empty", &pb.Response{Id: 5, Result: &pb.Response_Batch{Batch: &pb.Batch{Generation: gen}}}},
		{"done", &pb.Response{Id: 6, Result: &pb.Response_Done{Done: &pb.Done{}}}},
		{"account", &pb.Response{Id: 7, Result: &pb.Response_Account{Account: &pb.Account{Status: "temporarily_unavailable"}}}},
		{"shares", &pb.Response{Id: 8, Result: &pb.Response_Shares{Shares: &pb.SharesInfo{
			DataUrl: "https://www.icloud.com/share/0data", RelayUrl: "https://www.icloud.com/share/0relay",
		}}}},
		{"participant_list", &pb.Response{Id: 11, Result: &pb.Response_Participants{Participants: &pb.ParticipantList{Items: []*pb.Participant{
			{UserRecordName: "_user-a", Accepted: true}, {UserRecordName: "_user-b"},
		}}}}},
		{"owner_user_info", &pb.Response{Id: 13, Result: &pb.Response_OwnerUser{OwnerUser: &pb.OwnerUserInfo{UserRecordName: "_owner-acme"}}}},
		{"owner_user_info_empty", &pb.Response{Id: 13, Result: &pb.Response_OwnerUser{OwnerUser: &pb.OwnerUserInfo{}}}},
		{"failure", &pb.Response{Id: 4, Result: &pb.Response_Failure{Failure: &pb.Failure{Class: "token_expired"}}}},
		{"event_zone", &pb.Response{Result: &pb.Response_Event{Event: &pb.Event{Zone: relay}}}},
		{"event_pull_now", &pb.Response{Result: &pb.Response_Event{Event: &pb.Event{PullNow: true}}}},
		{"event_error", &pb.Response{Result: &pb.Response_Event{Event: &pb.Event{ErrorClass: "unavailable"}}}},
		{"event_account_changed", &pb.Response{Result: &pb.Response_Event{Event: &pb.Event{AccountChanged: true}}}},
	}
}

func messageName(m proto.Message) string { return string(m.ProtoReflect().Descriptor().Name()) }

func newMessage(t *testing.T, name string) proto.Message {
	t.Helper()
	switch name {
	case "Request":
		return &pb.Request{}
	case "Response":
		return &pb.Response{}
	}
	t.Fatalf("unknown message %q", name)
	return nil
}

func TestFramesFixture(t *testing.T) {
	jsonOpts := protojson.MarshalOptions{UseProtoNames: true}
	var want fixture
	want.Note = fixtureNote
	for _, c := range fixtureCases() {
		b, err := proto.MarshalOptions{Deterministic: true}.Marshal(c.msg)
		if err != nil {
			t.Fatal(err)
		}
		j, err := jsonOpts.Marshal(c.msg)
		if err != nil {
			t.Fatal(err)
		}
		var compact bytes.Buffer
		if err := json.Compact(&compact, j); err != nil {
			t.Fatal(err)
		}
		want.Cases = append(want.Cases, fixtureCase{Name: c.name, Message: messageName(c.msg), JSON: compact.Bytes(), Hex: hex.EncodeToString(b)})
	}
	if *update {
		b, err := json.MarshalIndent(want, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.FromSlash(fixturePath), append(b, '\n'), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	raw, err := os.ReadFile(filepath.FromSlash(fixturePath))
	if err != nil {
		t.Fatal(err)
	}
	var got fixture
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Cases) != len(want.Cases) {
		t.Fatalf("fixture has %d cases, the code %d (run with -update)", len(got.Cases), len(want.Cases))
	}
	seen := map[string]bool{}
	for i, c := range got.Cases {
		if c.Name != want.Cases[i].Name || c.Hex != want.Cases[i].Hex {
			t.Errorf("case %s: fixture differs from the code (run with -update)", c.Name)
		}
		b, err := hex.DecodeString(c.Hex)
		if err != nil {
			t.Fatalf("case %s: %v", c.Name, err)
		}
		fromHex, fromJSON := newMessage(t, c.Message), newMessage(t, c.Message)
		if err := proto.Unmarshal(b, fromHex); err != nil {
			t.Fatalf("case %s: decode: %v", c.Name, err)
		}
		if err := protojson.Unmarshal(c.JSON, fromJSON); err != nil {
			t.Fatalf("case %s: json: %v", c.Name, err)
		}
		if !proto.Equal(fromHex, fromJSON) {
			t.Errorf("case %s: hex and json disagree", c.Name)
		}
		again, err := proto.MarshalOptions{Deterministic: true}.Marshal(fromHex)
		if err != nil || !bytes.Equal(again, b) {
			t.Errorf("case %s: re-encoding differs", c.Name)
		}
		// Through the framing too: length prefix, then the same bytes.
		frame, err := cloudkit.EncodeFrame(fromHex)
		if err != nil || !bytes.Equal(frame[4:], b) || int(frame[0])<<24|int(frame[1])<<16|int(frame[2])<<8|int(frame[3]) != len(b) {
			t.Errorf("case %s: frame encoding differs", c.Name)
		}
		roundTrip := newMessage(t, c.Message)
		if raw, err := cloudkit.ReadFrame(bytes.NewReader(frame), roundTrip); err != nil || !bytes.Equal(raw, b) {
			t.Errorf("case %s: ReadFrame: %v", c.Name, err)
		}
		seen[c.Message+"."+oneofCase(fromHex)] = true
	}
	// Every op and every answer kind is pinned.
	for _, m := range []proto.Message{&pb.Request{}, &pb.Response{}} {
		d := m.ProtoReflect().Descriptor()
		fields := d.Oneofs().Get(0).Fields()
		for i := range fields.Len() {
			if k := string(d.Name()) + "." + string(fields.Get(i).Name()); !seen[k] {
				t.Errorf("no fixture case for %s", k)
			}
		}
	}
}

func oneofCase(m proto.Message) string {
	r := m.ProtoReflect()
	if f := r.WhichOneof(r.Descriptor().Oneofs().Get(0)); f != nil {
		return string(f.Name())
	}
	return ""
}

// TestFramesUseOnlyHandCodableFields: the Swift side hand-codes these
// messages, so every field is a varint or length-delimited scalar, a message,
// or a repeated message/string — no maps, floats, fixed-width or packed
// repeated scalars.
func TestFramesUseOnlyHandCodableFields(t *testing.T) {
	fd := pb.File_bridge_proto
	msgs := fd.Messages()
	for i := range msgs.Len() {
		m := msgs.Get(i)
		for j := range m.Fields().Len() {
			f := m.Fields().Get(j)
			name := string(m.Name()) + "." + string(f.Name())
			if f.IsMap() {
				t.Errorf("%s is a map", name)
			}
			switch f.Kind() {
			case protoreflect.BoolKind, protoreflect.EnumKind, protoreflect.Uint32Kind, protoreflect.Uint64Kind, protoreflect.Int64Kind:
				if f.IsList() {
					t.Errorf("%s is a repeated scalar (packed)", name)
				}
			case protoreflect.StringKind, protoreflect.BytesKind, protoreflect.MessageKind:
			default:
				t.Errorf("%s has kind %s", name, f.Kind())
			}
		}
	}
}

func TestReadFrameRefusesAnOversizedLength(t *testing.T) {
	head := []byte{0x00, 0x40, 0x00, 0x01} // MaxFrame + 1
	if _, err := cloudkit.ReadFrame(bytes.NewReader(head), &pb.Response{}); !errors.Is(err, cloudkit.ErrFrameTooLarge) {
		t.Fatalf("err %v, want ErrFrameTooLarge", err)
	}
	big := &pb.Request{Op: &pb.Request_Save{Save: &pb.Save{Items: []*pb.SaveItem{{Envelope: make([]byte, cloudkit.MaxFrame)}}}}}
	if _, err := cloudkit.EncodeFrame(big); !errors.Is(err, cloudkit.ErrFrameTooLarge) {
		t.Fatalf("encode err %v, want ErrFrameTooLarge", err)
	}
}
