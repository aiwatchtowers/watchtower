// Package relaytest is an in-process fake of the hosted relay over the
// copied proto (internal/hub/transport/relay/relayv1): POST /v1/op, the
// WebSocket at /v1/ws (hello, subscribe, pushed events) and opaque blob URLs
// for attachments. It keeps last-version records with a per-zone counter, as
// the relay does, and models the account side the hub depends on: pairing
// slots (open_pairing → Control{PAIRING_OPENED} to the hub, promote_pairing),
// direct slots (add_slot), the phones holding a hub with their paying flag
// (get_account_state), and Control{ENTITLEMENT_EXPIRED} to the hub when a
// phone stops paying (SetPaying). No attestation, no quotas, no zone access
// rules: every signed-in device reads and writes every zone.
//
// Test-only: never imported by production code
// (TestRelaytestIsImportedOnlyByTests).
package relaytest

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"

	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// pairingTTL is how long an opened pairing slot lives.
const pairingTTL = 10 * time.Minute

// writeTimeout bounds one pushed WebSocket frame.
const writeTimeout = 5 * time.Second

// Server is one fake relay. URL is its origin.
type Server struct {
	URL  string
	srv  *httptest.Server
	hits atomic.Int64 // every HTTP request, the WebSocket and blobs included

	mu           sync.Mutex
	ops          []string
	reqs         []*relayv1.Request
	frames       [][]byte                       // every op body, WebSocket frame and blob received
	fail         map[string][]relayv1.ErrorCode // op → codes, one per call
	zones        map[string]*zone
	blobs        map[string][]byte
	blobHeaders  []http.Header
	uploads      []*relayv1.CreateUpload
	attZone      map[string]string
	account      *relayv1.AccountState // answered verbatim to every get_account_state when set
	readers      [][]string
	subscribed   []string
	pageLimit    int
	hideLength   bool                // blob GETs stream with no Content-Length
	downloadBase string              // get_download URL base ("" = this server)
	saveOverride *relayv1.SaveResult // answered to the next save instead

	kinds    map[string]relayv1.DeviceKind // registered devices
	pairings map[string]pairing            // open pairing slots by id
	slots    map[string][]string           // phone → the hubs (Macs) its account holds, sorted
	paying   map[string]bool               // phone → paying; a phone not here pays
	nextSlot int

	conns   []*conn             // open WebSockets, oldest first
	pending map[string][][]byte // device → control frames for its next WebSocket
	last    *conn               // the WebSocket that subscribed last (Push)
	ready   chan struct{}       // closed at the first subscribe
}

type zone struct {
	seq  uint64
	recs map[string]*relayv1.Record
}

type pairing struct{ phone, mac string }

// conn is one open WebSocket and the zones it subscribed.
type conn struct {
	ws     *websocket.Conn
	device string
	zones  map[string]bool
}

// Start runs a fake relay until the test ends.
func Start(t testing.TB) *Server {
	t.Helper()
	s := &Server{
		fail: map[string][]relayv1.ErrorCode{}, zones: map[string]*zone{},
		blobs: map[string][]byte{}, attZone: map[string]string{},
		pageLimit: 500, ready: make(chan struct{}),
		kinds: map[string]relayv1.DeviceKind{}, pairings: map[string]pairing{},
		slots: map[string][]string{}, paying: map[string]bool{}, pending: map[string][][]byte{},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/op", s.serveOp)
	mux.HandleFunc("/v1/ws", s.serveWS)
	mux.HandleFunc("/blob/", s.serveBlob)
	s.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.hits.Add(1)
		mux.ServeHTTP(w, r)
	}))
	s.URL = s.srv.URL
	t.Cleanup(func() {
		s.mu.Lock()
		conns := slices.Clone(s.conns)
		s.mu.Unlock()
		for _, c := range conns {
			_ = c.ws.CloseNow()
		}
		s.srv.Close()
	})
	return s
}

// ---- test controls and reads ----

// Hits is the number of HTTP requests served (the WebSocket and blobs
// included).
func (s *Server) Hits() int64 { return s.hits.Load() }

// FailNext makes the next call of op answer code.
func (s *Server) FailNext(op string, code relayv1.ErrorCode) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.fail[op] = append(s.fail[op], code)
}

// Ops is every op seen, in order; WebSocket requests are "ws:<op>".
func (s *Server) Ops() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.ops)
}

// Requests is every HTTP request of op, in order.
func (s *Server) Requests(op string) []*relayv1.Request {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []*relayv1.Request
	for _, r := range s.reqs {
		if OpName(r) == op {
			out = append(out, r)
		}
	}
	return out
}

// Frames is every message the relay received, as bytes: op request bodies,
// WebSocket frames and uploaded blobs. A test looks for a plaintext marker
// in them (canary capture).
func (s *Server) Frames() [][]byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([][]byte, len(s.frames))
	for i, f := range s.frames {
		out[i] = slices.Clone(f)
	}
	return out
}

// Subscribed is every zone subscribed over any WebSocket, in order.
func (s *Server) Subscribed() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.subscribed)
}

// Readers is every set_hub_readers set, in order.
func (s *Server) Readers() [][]string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([][]string, len(s.readers))
	for i, r := range s.readers {
		out[i] = slices.Clone(r)
	}
	return out
}

// Uploads is every create_upload, in order.
func (s *Server) Uploads() []*relayv1.CreateUpload {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.uploads)
}

// Blob is an uploaded blob's bytes.
func (s *Server) Blob(id string) ([]byte, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b, ok := s.blobs[id]
	return slices.Clone(b), ok
}

// BlobHeaders is the headers of every blob upload, in order.
func (s *Server) BlobHeaders() []http.Header {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.blobHeaders)
}

// SetAccountState makes every get_account_state answer st as it is,
// whoever asks (nil = back to the modelled slots and paying flags).
func (s *Server) SetAccountState(st *relayv1.AccountState) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.account = st
}

// SetPageLimit caps the records of one changes page.
func (s *Server) SetPageLimit(n int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pageLimit = n
}

// SetHideLength makes blob downloads stream with no Content-Length.
func (s *Server) SetHideLength(hide bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hideLength = hide
}

// SetDownloadBase points get_download URLs at base ("" = this server).
func (s *Server) SetDownloadBase(base string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.downloadBase = base
}

// OverrideNextSave answers res to the next save instead of saving.
func (s *Server) OverrideNextSave(res *relayv1.SaveResult) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.saveOverride = res
}

// Put writes a record as a phone would, with no op and no event.
func (s *Server) Put(zoneName, name string, env []byte) uint64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	z := s.zone(zoneName)
	z.seq++
	z.recs[name] = &relayv1.Record{Zone: zoneName, Name: name, Envelope: env, RecordSeq: z.seq, ClientModifiedAtMs: 1}
	return z.seq
}

// Push sends a server event on the WebSocket that subscribed last, waiting
// up to 5 s for a first subscribe.
func (s *Server) Push(t testing.TB, ev *relayv1.Event) {
	t.Helper()
	select {
	case <-s.ready:
	case <-time.After(5 * time.Second):
		t.Fatal("relaytest: no WebSocket subscribed")
	}
	s.mu.Lock()
	c := s.last
	s.mu.Unlock()
	b, _ := proto.Marshal(&relayv1.Frame{Kind: &relayv1.Frame_Event{Event: ev}})
	if err := c.ws.Write(t.Context(), websocket.MessageBinary, b); err != nil {
		t.Fatal(err)
	}
}

// SetPaying sets whether phone's account pays (a phone pays until told
// otherwise). Turning it off sends Control{ENTITLEMENT_EXPIRED, detail: the
// phone's device id} to every hub the phone holds in a slot.
func (s *Server) SetPaying(phone string, paying bool) {
	s.mu.Lock()
	was := s.pays(phone)
	s.paying[phone] = paying
	var sends []send
	if was && !paying {
		for _, mac := range s.slots[phone] {
			sends = append(sends, s.controlLocked(mac, relayv1.ControlKind_CONTROL_KIND_ENTITLEMENT_EXPIRED, phone)...)
		}
	}
	s.mu.Unlock()
	deliver(sends)
}

// ---- ops ----

// OpName is the name of req's op field ("save", "open_pairing", …).
func OpName(req *relayv1.Request) string {
	m := req.ProtoReflect()
	fd := m.WhichOneof(m.Descriptor().Oneofs().ByName("op"))
	if fd == nil {
		return ""
	}
	return string(fd.Name())
}

func (s *Server) zone(name string) *zone {
	z := s.zones[name]
	if z == nil {
		z = &zone{recs: map[string]*relayv1.Record{}}
		s.zones[name] = z
	}
	return z
}

func (s *Server) pays(phone string) bool {
	p, ok := s.paying[phone]
	return !ok || p
}

func ok() *relayv1.Response {
	return &relayv1.Response{Result: &relayv1.Response_Ok{Ok: &relayv1.Ok{}}}
}

func errResp(code relayv1.ErrorCode) *relayv1.Response {
	return &relayv1.Response{Result: &relayv1.Response_Error{Error: &relayv1.Error{Code: code, Message: "fake"}}}
}

// tokenPrefix makes a session token name its device.
const tokenPrefix = "tok-"

func deviceOfToken(tok string) string { return strings.TrimPrefix(tok, tokenPrefix) }

func (s *Server) serveOp(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	var req relayv1.Request
	if err := proto.Unmarshal(body, &req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	caller := ""
	if tok, found := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer "); found {
		caller = deviceOfToken(tok)
	}
	s.mu.Lock()
	op := OpName(&req)
	s.ops = append(s.ops, op)
	s.reqs = append(s.reqs, proto.Clone(&req).(*relayv1.Request))
	s.frames = append(s.frames, body)
	var resp *relayv1.Response
	var sends []send
	if q := s.fail[op]; len(q) > 0 {
		s.fail[op] = q[1:]
		resp = errResp(q[0])
	} else {
		resp, sends = s.handle(caller, &req)
	}
	s.mu.Unlock()
	deliver(sends)
	b, _ := proto.Marshal(resp)
	w.Header().Set("Content-Type", "application/x-protobuf")
	_, _ = w.Write(b) //nolint:gosec // a protobuf answer of a test server, not HTML
}

// handle answers one op of caller (a device id, "" before login) and lists
// the events it sends; s.mu is held.
func (s *Server) handle(caller string, req *relayv1.Request) (*relayv1.Response, []send) {
	switch op := req.GetOp().(type) {
	case *relayv1.Request_Challenge:
		return &relayv1.Response{Result: &relayv1.Response_Challenge{Challenge: &relayv1.Challenge{Nonce: []byte("nonce")}}}, nil
	case *relayv1.Request_Login:
		return &relayv1.Response{Result: &relayv1.Response_Session{Session: &relayv1.Session{
			Token: tokenPrefix + op.Login.GetDeviceId()}}}, nil
	case *relayv1.Request_Register:
		id := client.DeviceID(op.Register.GetAuthPub())
		s.kinds[id] = op.Register.GetDeviceKind()
		reg := &relayv1.DeviceRegistered{DeviceId: id}
		if op.Register.GetDeviceKind() == relayv1.DeviceKind_DEVICE_KIND_PHONE {
			reg.AccountId = "acct-" + id
		}
		return &relayv1.Response{Result: &relayv1.Response_Registered{Registered: reg}}, nil
	case *relayv1.Request_Save:
		if o := s.saveOverride; o != nil {
			s.saveOverride = nil
			return &relayv1.Response{Result: &relayv1.Response_Save{Save: o}}, nil
		}
		return s.save(caller, op.Save)
	case *relayv1.Request_Delete:
		return s.del(caller, op.Delete)
	case *relayv1.Request_Changes:
		return s.changes(op.Changes), nil
	case *relayv1.Request_SetHubReaders:
		s.readers = append(s.readers, slices.Clone(op.SetHubReaders.GetPhoneDeviceIds()))
		return ok(), nil
	case *relayv1.Request_GetAccountState:
		return &relayv1.Response{Result: &relayv1.Response_AccountState{AccountState: s.accountState(caller)}}, nil
	case *relayv1.Request_OpenPairing:
		return s.openPairing(caller, op.OpenPairing.GetMacDeviceId())
	case *relayv1.Request_PromotePairing:
		p, found := s.pairings[op.PromotePairing.GetSlotId()]
		if !found || p.phone != caller {
			return errResp(relayv1.ErrorCode_ERROR_CODE_PAIRING_EXPIRED), nil
		}
		delete(s.pairings, op.PromotePairing.GetSlotId())
		s.addSlot(caller, p.mac)
		return ok(), nil
	case *relayv1.Request_AddSlot:
		if caller == "" || op.AddSlot.GetMacDeviceId() == "" {
			return errResp(relayv1.ErrorCode_ERROR_CODE_FORBIDDEN), nil
		}
		s.addSlot(caller, op.AddSlot.GetMacDeviceId())
		return ok(), nil
	case *relayv1.Request_CreateUpload:
		id := "att-" + strconv.Itoa(len(s.uploads)+1)
		s.uploads = append(s.uploads, op.CreateUpload)
		s.attZone[id] = op.CreateUpload.GetZone()
		return &relayv1.Response{Result: &relayv1.Response_Upload{Upload: &relayv1.Upload{
			AttachmentId: id, Url: s.URL + "/blob/" + id + "?X-Sig=opaque%2Fsig",
			Headers: map[string]string{"X-Test-Upload": "yes"},
		}}}, nil
	case *relayv1.Request_GetDownload:
		id := op.GetDownload.GetAttachmentId()
		if s.attZone[id] != op.GetDownload.GetZone() {
			return errResp(relayv1.ErrorCode_ERROR_CODE_FORBIDDEN), nil
		}
		base := s.downloadBase
		if base == "" {
			base = s.URL
		}
		return &relayv1.Response{Result: &relayv1.Response_Download{Download: &relayv1.Download{Url: base + "/blob/" + id + "?X-Sig=get"}}}, nil
	default:
		return errResp(relayv1.ErrorCode_ERROR_CODE_UNSPECIFIED), nil
	}
}

// accountState is a phone's (its hubs and entitlement) or a hub's (the
// phones holding it, sorted, with their paying flag) account state.
func (s *Server) accountState(caller string) *relayv1.AccountState {
	if s.account != nil {
		return proto.Clone(s.account).(*relayv1.AccountState)
	}
	if s.kinds[caller] == relayv1.DeviceKind_DEVICE_KIND_PHONE {
		state := relayv1.EntitlementKind_ENTITLEMENT_KIND_ACTIVE
		if !s.pays(caller) {
			state = relayv1.EntitlementKind_ENTITLEMENT_KIND_EXPIRED
		}
		return &relayv1.AccountState{
			Entitlement:  &relayv1.EntitlementState{State: state},
			MacDeviceIds: slices.Clone(s.slots[caller]),
		}
	}
	st := &relayv1.AccountState{}
	phones := make([]string, 0, len(s.slots))
	for phone := range s.slots {
		phones = append(phones, phone)
	}
	sort.Strings(phones)
	for _, phone := range phones {
		if slices.Contains(s.slots[phone], caller) {
			st.Phones = append(st.Phones, &relayv1.SlotHolder{PhoneDeviceId: phone, Paying: s.pays(phone)})
		}
	}
	return st
}

func (s *Server) openPairing(caller, mac string) (*relayv1.Response, []send) {
	if caller == "" || mac == "" {
		return errResp(relayv1.ErrorCode_ERROR_CODE_FORBIDDEN), nil
	}
	s.nextSlot++
	slot := "slot" + strconv.Itoa(s.nextSlot)
	s.pairings[slot] = pairing{phone: caller, mac: mac}
	sends := s.controlLocked(mac, relayv1.ControlKind_CONTROL_KIND_PAIRING_OPENED, slot)
	return &relayv1.Response{Result: &relayv1.Response_PairingSlot{PairingSlot: &relayv1.PairingSlot{
		SlotId: slot, ExpiresAtMs: time.Now().Add(pairingTTL).UnixMilli(),
	}}}, sends
}

func (s *Server) addSlot(phone, mac string) {
	if !slices.Contains(s.slots[phone], mac) {
		s.slots[phone] = append(s.slots[phone], mac)
		slices.Sort(s.slots[phone])
	}
}

func live(r *relayv1.Record) bool { return r != nil && !r.GetDeleted() }

func (s *Server) save(caller string, sv *relayv1.Save) (*relayv1.Response, []send) {
	res := &relayv1.SaveResult{}
	var sends []send
	for i, it := range sv.GetItems() {
		rec := it.GetRecord()
		z := s.zone(rec.GetZone())
		cur := z.recs[rec.GetName()]
		conflict := false
		switch e := it.GetExpect().(type) {
		case *relayv1.SaveItem_MustNotExist:
			conflict = live(cur)
		case *relayv1.SaveItem_ExpectedSeq:
			conflict = !live(cur) || cur.GetRecordSeq() != e.ExpectedSeq
		}
		if conflict {
			c := &relayv1.SaveConflict{Index: uint32(i)}
			if live(cur) {
				c.Current = proto.Clone(cur).(*relayv1.Record)
			}
			res.Conflicts = append(res.Conflicts, c)
			continue
		}
		z.seq++
		stored := proto.Clone(rec).(*relayv1.Record)
		stored.RecordSeq = z.seq
		z.recs[rec.GetName()] = stored
		meta := proto.Clone(stored).(*relayv1.Record)
		meta.Envelope = nil
		res.Saved = append(res.Saved, meta)
		sends = append(sends, s.zoneChangedLocked(caller, rec.GetZone(), z.seq)...)
	}
	return &relayv1.Response{Result: &relayv1.Response_Save{Save: res}}, sends
}

func (s *Server) del(caller string, d *relayv1.Delete) (*relayv1.Response, []send) {
	res := &relayv1.DeleteResult{}
	z := s.zone(d.GetZone())
	var sends []send
	for i, it := range d.GetItems() {
		cur := z.recs[it.GetName()]
		if it.ExpectedSeq != nil && (!live(cur) || cur.GetRecordSeq() != it.GetExpectedSeq()) {
			c := &relayv1.DeleteConflict{Index: uint32(i)}
			if live(cur) {
				c.Current = proto.Clone(cur).(*relayv1.Record)
			}
			res.Conflicts = append(res.Conflicts, c)
			continue
		}
		if live(cur) {
			z.seq++
			z.recs[it.GetName()] = &relayv1.Record{Zone: d.GetZone(), Name: it.GetName(), RecordSeq: z.seq, Deleted: true}
			sends = append(sends, s.zoneChangedLocked(caller, d.GetZone(), z.seq)...)
		}
	}
	return &relayv1.Response{Result: &relayv1.Response_Delete{Delete: res}}, sends
}

func (s *Server) changes(c *relayv1.Changes) *relayv1.Response {
	z := s.zone(c.GetZone())
	if c.GetSinceSeq() > z.seq {
		return errResp(relayv1.ErrorCode_ERROR_CODE_TOKEN_EXPIRED)
	}
	var recs []*relayv1.Record
	for _, r := range z.recs {
		if r.GetRecordSeq() > c.GetSinceSeq() {
			recs = append(recs, r)
		}
	}
	sort.Slice(recs, func(i, j int) bool { return recs[i].GetRecordSeq() < recs[j].GetRecordSeq() })
	res := &relayv1.ChangesResult{NewSeq: z.seq}
	if len(recs) > s.pageLimit {
		recs, res.More = recs[:s.pageLimit], true
		res.NewSeq = recs[len(recs)-1].GetRecordSeq()
	}
	for _, r := range recs {
		if r.GetDeleted() {
			res.Deleted = append(res.Deleted, r.GetName())
		} else {
			res.Changed = append(res.Changed, proto.Clone(r).(*relayv1.Record))
		}
	}
	return &relayv1.Response{Result: &relayv1.Response_Changes{Changes: res}}
}

func (s *Server) serveBlob(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/blob/")
	s.mu.Lock()
	defer s.mu.Unlock()
	switch r.Method {
	case http.MethodPut:
		b, _ := io.ReadAll(r.Body)
		s.blobs[id] = b
		s.blobHeaders = append(s.blobHeaders, r.Header.Clone())
		s.frames = append(s.frames, b)
	case http.MethodGet:
		b, found := s.blobs[id]
		if !found {
			http.NotFound(w, r)
			return
		}
		if s.hideLength {
			w.(http.Flusher).Flush() // headers out first: chunked, no Content-Length
		} else {
			w.Header().Set("Content-Length", strconv.Itoa(len(b)))
		}
		_, _ = w.Write(b)
	default:
		http.Error(w, "method", http.StatusMethodNotAllowed)
	}
}

// ---- the WebSocket ----

// send is one frame for one WebSocket, written after s.mu is released.
type send struct {
	ws    *websocket.Conn
	frame []byte
}

func deliver(sends []send) {
	for _, sd := range sends {
		ctx, cancel := context.WithTimeout(context.Background(), writeTimeout)
		_ = sd.ws.Write(ctx, websocket.MessageBinary, sd.frame) // a closed socket: the device reads on reconnect
		cancel()
	}
}

func eventFrame(ev *relayv1.Event) []byte {
	b, _ := proto.Marshal(&relayv1.Frame{Kind: &relayv1.Frame_Event{Event: ev}})
	return b
}

// controlLocked is a control for device: on every WebSocket it has open, or
// held for its next one; s.mu is held.
func (s *Server) controlLocked(device string, kind relayv1.ControlKind, detail string) []send {
	b := eventFrame(&relayv1.Event{Kind: &relayv1.Event_Control{Control: &relayv1.Control{Kind: kind, Detail: detail}}})
	var sends []send
	for _, c := range s.conns {
		if c.device == device {
			sends = append(sends, send{c.ws, b})
		}
	}
	if len(sends) == 0 {
		s.pending[device] = append(s.pending[device], b)
	}
	return sends
}

// zoneChangedLocked tells every other device's WebSocket subscribed to
// zoneName that it changed (the writer is not told); s.mu is held.
func (s *Server) zoneChangedLocked(writer, zoneName string, seq uint64) []send {
	var sends []send
	for _, c := range s.conns {
		if c.device != writer && c.zones[zoneName] {
			sends = append(sends, send{c.ws, eventFrame(&relayv1.Event{Kind: &relayv1.Event_ZoneChanged{
				ZoneChanged: &relayv1.ZoneChanged{Zone: zoneName, Seq: seq}}})})
		}
	}
	return sends
}

func (s *Server) serveWS(w http.ResponseWriter, r *http.Request) {
	ws, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	ctx := context.Background()
	_, b, err := ws.Read(ctx)
	if err != nil {
		return
	}
	var hello relayv1.Frame
	_ = proto.Unmarshal(b, &hello)
	helloOK, _ := proto.Marshal(&relayv1.Frame{Kind: &relayv1.Frame_HelloOk{HelloOk: &relayv1.HelloOk{ConnectionId: "c"}}})
	if ws.Write(ctx, websocket.MessageBinary, helloOK) != nil {
		return
	}
	c := &conn{ws: ws, device: deviceOfToken(hello.GetHello().GetSessionToken()), zones: map[string]bool{}}
	s.mu.Lock()
	s.frames = append(s.frames, b)
	s.conns = append(s.conns, c)
	var sends []send
	for _, f := range s.pending[c.device] {
		sends = append(sends, send{ws, f})
	}
	delete(s.pending, c.device)
	s.mu.Unlock()
	deliver(sends)
	defer func() {
		s.mu.Lock()
		s.conns = slices.DeleteFunc(s.conns, func(o *conn) bool { return o == c })
		s.mu.Unlock()
	}()
	for {
		_, b, err := ws.Read(ctx)
		if err != nil {
			return
		}
		var fr relayv1.Frame
		if proto.Unmarshal(b, &fr) != nil || fr.GetRequest() == nil {
			continue
		}
		req := fr.GetRequest()
		s.mu.Lock()
		s.frames = append(s.frames, b)
		s.ops = append(s.ops, "ws:"+OpName(req))
		zones := req.GetSubscribe().GetZones()
		s.subscribed = append(s.subscribed, zones...)
		for _, z := range zones {
			c.zones[z] = true
		}
		first := len(s.subscribed) > 0 && req.GetSubscribe() != nil
		if req.GetSubscribe() != nil {
			s.last = c
		}
		s.mu.Unlock()
		out, _ := proto.Marshal(&relayv1.Frame{Kind: &relayv1.Frame_Response{Response: &relayv1.Response{
			Id: req.GetId(), Result: &relayv1.Response_Ok{Ok: &relayv1.Ok{}}}}})
		if ws.Write(ctx, websocket.MessageBinary, out) != nil {
			return
		}
		if first {
			select {
			case <-s.ready:
			default:
				close(s.ready)
			}
		}
	}
}
