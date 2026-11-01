// Package relaytest is an in-process fake of the hosted relay over the
// copied proto (internal/hub/transport/relay/relayv1): POST /v1/op, the
// WebSocket at /v1/ws (hello, subscribe, pushed events) and opaque blob URLs
// for attachments. It keeps last-version records with a per-zone counter, as
// the relay does, and models the account side the hub depends on: pairing
// slots (open_pairing → Control{PAIRING_OPENED} to the hub, promote_pairing),
// direct slots (add_slot), the phones holding a hub with their paying flag
// (get_account_state), and Control{ENTITLEMENT_EXPIRED} to the hub when a
// phone stops paying (SetPaying).
//
// Vouched hubs (relay proto README, "Vouched hubs"): a hub (DEVICE_KIND_HUB or
// DEVICE_KIND_MAC) in no phone's slot may only run get_account_state,
// subscribe, close_pairing and save/delete/changes on pair/ zones; every
// other op, over HTTP or its open socket, answers HUB_NOT_VOUCHED. A phone
// vouches for a hub with a VOUCH challenge and vouch_hub (checked in the
// relay's order: FORBIDDEN, ENTITLEMENT_INACTIVE, ATTESTATION_FAILED for a
// nonce that is not an unused VOUCH nonce of this phone, NOT_FOUND, SLOT_LIMIT;
// attestation itself is not modelled: FailNext("vouch_hub", …) stands in), and
// the pending vouch lives 10 minutes; promote_pairing and add_slot of a hub
// not yet in the phone's slots consume it or answer HUB_NOT_VOUCHED. A hub
// newly put into a slot gets Control{SLOT_ADDED, detail: the phone's device
// id}, best effort: only on an open socket, dropped otherwise. No quotas and
// no zone access rules beyond that: every device that may write a zone
// reads and writes every zone.
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

// VouchTTL is how long a phone's pending vouch for a hub lives.
const VouchTTL = 10 * time.Minute

// maxMacs is the hubs one account may hold in its slots.
const maxMacs = 3

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
	failSave     map[string]relayv1.ErrorCode   // zone → code for the next save into it
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

	vouches     map[string]map[string]time.Time // phone → hub → when its pending vouch expires
	vouchNonces map[string]string               // unused VOUCH nonce → the phone it was issued to
	nextNonce   int
	now         func() time.Time

	conns      map[string]*conn   // device → its current WebSocket
	all        []*conn            // every WebSocket accepted (closed at cleanup)
	pending    map[string][]frame // device → controls for its next WebSocket
	lastDevice string             // the device that subscribed last (Push)
	ready      chan struct{}      // closed at the first subscribe
}

type zone struct {
	seq  uint64
	recs map[string]*relayv1.Record
}

type pairing struct{ phone, mac string }

// Start runs a fake relay until the test ends.
func Start(t testing.TB) *Server {
	t.Helper()
	s := &Server{
		fail: map[string][]relayv1.ErrorCode{}, failSave: map[string]relayv1.ErrorCode{}, zones: map[string]*zone{},
		blobs: map[string][]byte{}, attZone: map[string]string{},
		pageLimit: 500, ready: make(chan struct{}),
		kinds: map[string]relayv1.DeviceKind{}, pairings: map[string]pairing{},
		slots: map[string][]string{}, paying: map[string]bool{}, conns: map[string]*conn{}, pending: map[string][]frame{},
		vouches: map[string]map[string]time.Time{}, vouchNonces: map[string]string{}, now: time.Now,
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
		conns := slices.Clone(s.all)
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

// FailNextSaveIn makes the next save with an item in zone answer code. With
// HUB_NOT_VOUCHED the caller also leaves every slot at that moment, with no
// control, so the account state agrees with the answer.
func (s *Server) FailNextSaveIn(zone string, code relayv1.ErrorCode) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.failSave[zone] = code
}

// failSaveInLocked takes a FailNextSaveIn code for caller's req; s.mu is
// held.
func (s *Server) failSaveInLocked(caller string, req *relayv1.Request) (relayv1.ErrorCode, bool) {
	for _, it := range req.GetSave().GetItems() {
		code, found := s.failSave[it.GetRecord().GetZone()]
		if !found {
			continue
		}
		delete(s.failSave, it.GetRecord().GetZone())
		if code == relayv1.ErrorCode_ERROR_CODE_HUB_NOT_VOUCHED {
			for phone, macs := range s.slots {
				s.slots[phone] = slices.DeleteFunc(macs, func(m string) bool { return m == caller })
			}
		}
		return code, true
	}
	return 0, false
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

// Push queues a server event on the current WebSocket of the device that
// subscribed last, waiting up to 5 s for a first subscribe. A control
// pushed while that device has no socket waits for its next one.
func (s *Server) Push(t testing.TB, ev *relayv1.Event) {
	t.Helper()
	select {
	case <-s.ready:
	case <-time.After(5 * time.Second):
		t.Fatal("relaytest: no WebSocket subscribed")
	}
	f := frame{b: eventFrame(ev), control: ev.GetControl() != nil}
	s.mu.Lock()
	defer s.mu.Unlock()
	if c := s.conns[s.lastDevice]; c != nil && !c.closed {
		c.enqueueLocked(f)
		return
	}
	s.parkLocked(s.lastDevice, []frame{f})
}

// SetPaying sets whether phone's account pays (a phone pays until told
// otherwise). Turning it off sends Control{ENTITLEMENT_EXPIRED, detail: the
// phone's device id} to every hub the phone holds in a slot.
func (s *Server) SetPaying(phone string, paying bool) {
	s.mu.Lock()
	was := s.pays(phone)
	s.paying[phone] = paying
	if was && !paying {
		for _, mac := range s.slots[phone] {
			s.controlLocked(mac, relayv1.ControlKind_CONTROL_KIND_ENTITLEMENT_EXPIRED, phone)
		}
	}
	s.mu.Unlock()
}

// SetNow replaces the relay's clock (pending vouch expiry).
func (s *Server) SetNow(now func() time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.now = now
}

// RemoveSlot takes hub out of phone's slots (remove_slot, a subscription
// moving away) and sends the hub Control{SLOT_REMOVED, detail: phone}. A hub
// left in no slot is unvouched again; its registration stays.
func (s *Server) RemoveSlot(phone, hub string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if i := slices.Index(s.slots[phone], hub); i >= 0 {
		s.slots[phone] = slices.Delete(s.slots[phone], i, i+1)
		s.controlLocked(hub, relayv1.ControlKind_CONTROL_KIND_SLOT_REMOVED, phone)
	}
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
	if q := s.fail[op]; len(q) > 0 {
		s.fail[op] = q[1:]
		resp = errResp(q[0])
	} else if code, found := s.failSaveInLocked(caller, &req); found {
		resp = errResp(code)
	} else {
		resp = s.handle(caller, &req)
	}
	s.mu.Unlock()
	b, _ := proto.Marshal(resp)
	w.Header().Set("Content-Type", "application/x-protobuf")
	_, _ = w.Write(b)
}

// handle answers one op of caller (a device id, "" before login) and queues
// the events it causes; s.mu is held.
func (s *Server) handle(caller string, req *relayv1.Request) *relayv1.Response {
	if s.isHub(caller) && !s.vouched(caller) && !unvouchedAllowed(req) {
		return errResp(relayv1.ErrorCode_ERROR_CODE_HUB_NOT_VOUCHED)
	}
	switch op := req.GetOp().(type) {
	case *relayv1.Request_Challenge:
		nonce := []byte("nonce")
		if op.Challenge.GetPurpose() == relayv1.ChallengePurpose_CHALLENGE_PURPOSE_VOUCH {
			s.nextNonce++
			nonce = []byte("vouch-" + strconv.Itoa(s.nextNonce))
			s.vouchNonces[string(nonce)] = op.Challenge.GetDeviceId()
		}
		return &relayv1.Response{Result: &relayv1.Response_Challenge{Challenge: &relayv1.Challenge{Nonce: nonce}}}
	case *relayv1.Request_VouchHub:
		return s.vouchHub(caller, op.VouchHub)
	case *relayv1.Request_Login:
		return &relayv1.Response{Result: &relayv1.Response_Session{Session: &relayv1.Session{
			Token: tokenPrefix + op.Login.GetDeviceId()}}}
	case *relayv1.Request_Register:
		id := client.DeviceID(op.Register.GetAuthPub())
		s.kinds[id] = op.Register.GetDeviceKind()
		reg := &relayv1.DeviceRegistered{DeviceId: id}
		if op.Register.GetDeviceKind() == relayv1.DeviceKind_DEVICE_KIND_PHONE {
			reg.AccountId = "acct-" + id
		}
		return &relayv1.Response{Result: &relayv1.Response_Registered{Registered: reg}}
	case *relayv1.Request_Save:
		if o := s.saveOverride; o != nil {
			s.saveOverride = nil
			return &relayv1.Response{Result: &relayv1.Response_Save{Save: o}}
		}
		return s.save(caller, op.Save)
	case *relayv1.Request_Delete:
		return s.del(caller, op.Delete)
	case *relayv1.Request_Changes:
		return s.changes(op.Changes)
	case *relayv1.Request_SetHubReaders:
		s.readers = append(s.readers, slices.Clone(op.SetHubReaders.GetPhoneDeviceIds()))
		return ok()
	case *relayv1.Request_GetAccountState:
		return &relayv1.Response{Result: &relayv1.Response_AccountState{AccountState: s.accountState(caller)}}
	case *relayv1.Request_OpenPairing:
		return s.openPairing(caller, op.OpenPairing.GetMacDeviceId())
	case *relayv1.Request_PromotePairing:
		p, found := s.pairings[op.PromotePairing.GetSlotId()]
		if !found || p.phone != caller {
			return errResp(relayv1.ErrorCode_ERROR_CODE_PAIRING_EXPIRED)
		}
		if code := s.addSlot(caller, p.mac); code != relayv1.ErrorCode_ERROR_CODE_UNSPECIFIED {
			return errResp(code)
		}
		delete(s.pairings, op.PromotePairing.GetSlotId())
		return ok()
	case *relayv1.Request_AddSlot:
		if caller == "" || op.AddSlot.GetMacDeviceId() == "" {
			return errResp(relayv1.ErrorCode_ERROR_CODE_FORBIDDEN)
		}
		if code := s.addSlot(caller, op.AddSlot.GetMacDeviceId()); code != relayv1.ErrorCode_ERROR_CODE_UNSPECIFIED {
			return errResp(code)
		}
		return ok()
	case *relayv1.Request_CreateUpload:
		id := "att-" + strconv.Itoa(len(s.uploads)+1)
		s.uploads = append(s.uploads, op.CreateUpload)
		s.attZone[id] = op.CreateUpload.GetZone()
		return &relayv1.Response{Result: &relayv1.Response_Upload{Upload: &relayv1.Upload{
			AttachmentId: id, Url: s.URL + "/blob/" + id + "?X-Sig=opaque%2Fsig",
			Headers: map[string]string{"X-Test-Upload": "yes"},
		}}}
	case *relayv1.Request_GetDownload:
		id := op.GetDownload.GetAttachmentId()
		if s.attZone[id] != op.GetDownload.GetZone() {
			return errResp(relayv1.ErrorCode_ERROR_CODE_FORBIDDEN)
		}
		base := s.downloadBase
		if base == "" {
			base = s.URL
		}
		return &relayv1.Response{Result: &relayv1.Response_Download{Download: &relayv1.Download{Url: base + "/blob/" + id + "?X-Sig=get"}}}
	default:
		return errResp(relayv1.ErrorCode_ERROR_CODE_UNSPECIFIED)
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

func (s *Server) openPairing(caller, mac string) *relayv1.Response {
	if caller == "" || mac == "" {
		return errResp(relayv1.ErrorCode_ERROR_CODE_FORBIDDEN)
	}
	s.nextSlot++
	slot := "slot" + strconv.Itoa(s.nextSlot)
	s.pairings[slot] = pairing{phone: caller, mac: mac}
	s.controlLocked(mac, relayv1.ControlKind_CONTROL_KIND_PAIRING_OPENED, slot)
	return &relayv1.Response{Result: &relayv1.Response_PairingSlot{PairingSlot: &relayv1.PairingSlot{
		SlotId: slot, ExpiresAtMs: time.Now().Add(pairingTTL).UnixMilli(),
	}}}
}

// addSlot puts mac into phone's slots (add_slot, promote_pairing). A hub
// already there is idempotent and needs no vouch; otherwise the account must
// have room (SLOT_LIMIT, the vouch kept) and a live pending vouch of this
// phone for it, which it consumes (HUB_NOT_VOUCHED). The hub gets SLOT_ADDED
// on its open socket. It returns UNSPECIFIED on success.
func (s *Server) addSlot(phone, mac string) relayv1.ErrorCode {
	if slices.Contains(s.slots[phone], mac) {
		return relayv1.ErrorCode_ERROR_CODE_UNSPECIFIED
	}
	if len(s.slots[phone]) >= maxMacs {
		return relayv1.ErrorCode_ERROR_CODE_SLOT_LIMIT
	}
	if exp, found := s.vouches[phone][mac]; !found || !s.now().Before(exp) {
		return relayv1.ErrorCode_ERROR_CODE_HUB_NOT_VOUCHED
	}
	delete(s.vouches[phone], mac)
	s.slots[phone] = append(s.slots[phone], mac)
	slices.Sort(s.slots[phone])
	s.liveControlLocked(mac, relayv1.ControlKind_CONTROL_KIND_SLOT_ADDED, phone)
	return relayv1.ErrorCode_ERROR_CODE_UNSPECIFIED
}

// vouchHub is a phone's vouch_hub, checked in the relay's order.
func (s *Server) vouchHub(caller string, v *relayv1.VouchHub) *relayv1.Response {
	if s.kinds[caller] != relayv1.DeviceKind_DEVICE_KIND_PHONE {
		return errResp(relayv1.ErrorCode_ERROR_CODE_FORBIDDEN)
	}
	if !s.pays(caller) {
		return errResp(relayv1.ErrorCode_ERROR_CODE_ENTITLEMENT_INACTIVE)
	}
	issued, found := s.vouchNonces[string(v.GetNonce())]
	delete(s.vouchNonces, string(v.GetNonce())) // spent, whatever follows
	if !found || issued != caller {
		return errResp(relayv1.ErrorCode_ERROR_CODE_ATTESTATION_FAILED)
	}
	hub := v.GetHubDeviceId()
	if len(v.GetAuthPub()) == 0 || client.DeviceID(v.GetAuthPub()) != hub || !s.isHub(hub) {
		return errResp(relayv1.ErrorCode_ERROR_CODE_NOT_FOUND)
	}
	if !slices.Contains(s.slots[caller], hub) && len(s.slots[caller]) >= maxMacs {
		return errResp(relayv1.ErrorCode_ERROR_CODE_SLOT_LIMIT)
	}
	if s.vouches[caller] == nil {
		s.vouches[caller] = map[string]time.Time{}
	}
	s.vouches[caller][hub] = s.now().Add(VouchTTL)
	return ok()
}

// isHub: device registered as a hub (either hub kind).
func (s *Server) isHub(device string) bool {
	k := s.kinds[device]
	return k == relayv1.DeviceKind_DEVICE_KIND_HUB || k == relayv1.DeviceKind_DEVICE_KIND_MAC
}

// vouched: the hub is in some phone's slot (or, with SetAccountState, the
// answered state lists a phone).
func (s *Server) vouched(hub string) bool {
	if s.account != nil {
		return len(s.account.GetPhones()) > 0
	}
	for _, macs := range s.slots {
		if slices.Contains(macs, hub) {
			return true
		}
	}
	return false
}

// unvouchedAllowed is what an unvouched hub may run (the relay's list): its
// sign-in, its account state, subscribe, close_pairing, vouch_hub (which
// answers a hub FORBIDDEN) and zone ops on pair/ zones only.
func unvouchedAllowed(req *relayv1.Request) bool {
	pair := func(zone string) bool { return strings.HasPrefix(zone, "pair/") }
	switch op := req.GetOp().(type) {
	case *relayv1.Request_Challenge, *relayv1.Request_Register, *relayv1.Request_Login,
		*relayv1.Request_GetAccountState, *relayv1.Request_Subscribe, *relayv1.Request_ClosePairing,
		*relayv1.Request_VouchHub:
		return true
	case *relayv1.Request_Save:
		if len(op.Save.GetItems()) == 0 {
			return false
		}
		for _, it := range op.Save.GetItems() {
			if !pair(it.GetRecord().GetZone()) {
				return false
			}
		}
		return true
	case *relayv1.Request_Delete:
		return pair(op.Delete.GetZone())
	case *relayv1.Request_Changes:
		return pair(op.Changes.GetZone())
	default:
		return false
	}
}

func live(r *relayv1.Record) bool { return r != nil && !r.GetDeleted() }

func (s *Server) save(caller string, sv *relayv1.Save) *relayv1.Response {
	res := &relayv1.SaveResult{}
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
		s.zoneChangedLocked(caller, rec.GetZone(), z.seq)
	}
	return &relayv1.Response{Result: &relayv1.Response_Save{Save: res}}
}

func (s *Server) del(caller string, d *relayv1.Delete) *relayv1.Response {
	res := &relayv1.DeleteResult{}
	z := s.zone(d.GetZone())
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
			s.zoneChangedLocked(caller, d.GetZone(), z.seq)
		}
	}
	return &relayv1.Response{Result: &relayv1.Response_Delete{Delete: res}}
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
//
// Every device has at most one current WebSocket (a new one replaces the
// old for events). Server events go through the connection's queue, written
// by one goroutine in the order they were queued under s.mu (op order), so
// a socket sees zone events in seq order whoever wrote. A control is never
// lost: queued while the device has no socket, and put back when a write
// fails or the socket ends before it went out, it goes to the device's next
// socket. A zone event on a dead socket is dropped: a reconnecting client
// resubscribes and pulls every zone anyway.

// frame is one queued server event.
type frame struct {
	b       []byte
	control bool
}

// conn is one open WebSocket, the zones it subscribed and its queue.
type conn struct {
	ws     *websocket.Conn
	device string
	zones  map[string]bool
	queue  []frame       // s.mu
	closed bool          // s.mu: ended; nothing more is queued here
	wake   chan struct{} // cap 1: the queue grew
	done   chan struct{} // closed when the socket ends
}

func eventFrame(ev *relayv1.Event) []byte {
	b, _ := proto.Marshal(&relayv1.Frame{Kind: &relayv1.Frame_Event{Event: ev}})
	return b
}

// enqueueLocked queues frames on c; s.mu is held and c is open.
func (c *conn) enqueueLocked(fs ...frame) {
	c.queue = append(c.queue, fs...)
	select {
	case c.wake <- struct{}{}:
	default:
	}
}

// parkLocked hands the controls among fs to device's current socket, or
// holds them for its next one; zone events are dropped. s.mu is held.
func (s *Server) parkLocked(device string, fs []frame) {
	var controls []frame
	for _, f := range fs {
		if f.control {
			controls = append(controls, f)
		}
	}
	if len(controls) == 0 {
		return
	}
	if c := s.conns[device]; c != nil && !c.closed {
		c.enqueueLocked(controls...)
		return
	}
	s.pending[device] = append(s.pending[device], controls...)
}

// controlLocked sends a control to device; s.mu is held.
func (s *Server) controlLocked(device string, kind relayv1.ControlKind, detail string) {
	b := eventFrame(&relayv1.Event{Kind: &relayv1.Event_Control{Control: &relayv1.Control{Kind: kind, Detail: detail}}})
	s.parkLocked(device, []frame{{b: b, control: true}})
}

// liveControlLocked sends a best-effort control: on device's open socket,
// dropped when it has none (the relay's SLOT_ADDED); s.mu is held.
func (s *Server) liveControlLocked(device string, kind relayv1.ControlKind, detail string) {
	if c := s.conns[device]; c != nil && !c.closed {
		b := eventFrame(&relayv1.Event{Kind: &relayv1.Event_Control{Control: &relayv1.Control{Kind: kind, Detail: detail}}})
		c.enqueueLocked(frame{b: b, control: true})
	}
}

// zoneChangedLocked tells every other device's current socket subscribed
// to zoneName that it changed (the writer is not told); s.mu is held.
func (s *Server) zoneChangedLocked(writer, zoneName string, seq uint64) {
	for device, c := range s.conns {
		if device != writer && !c.closed && c.zones[zoneName] {
			c.enqueueLocked(frame{b: eventFrame(&relayv1.Event{Kind: &relayv1.Event_ZoneChanged{
				ZoneChanged: &relayv1.ZoneChanged{Zone: zoneName, Seq: seq}}})})
		}
	}
}

// writeLoop writes c's queue in order until the socket ends or a write
// fails; what was not written goes back to c's queue (or, once c ended, is
// parked) and the socket is closed.
func (s *Server) writeLoop(c *conn) {
	for {
		select {
		case <-c.wake:
		case <-c.done:
			return
		}
		s.mu.Lock()
		batch := c.queue
		c.queue = nil
		s.mu.Unlock()
		for i, f := range batch {
			ctx, cancel := context.WithTimeout(context.Background(), writeTimeout)
			err := c.ws.Write(ctx, websocket.MessageBinary, f.b)
			cancel()
			if err != nil {
				s.mu.Lock()
				if c.closed {
					s.parkLocked(c.device, batch[i:])
				} else {
					c.queue = append(slices.Clone(batch[i:]), c.queue...)
				}
				s.mu.Unlock()
				_ = c.ws.CloseNow() // the reader ends and parks the queue
				return
			}
		}
	}
}

// end retires c: no longer current, its unsent controls parked.
func (s *Server) end(c *conn) {
	s.mu.Lock()
	c.closed = true
	if s.conns[c.device] == c {
		delete(s.conns, c.device)
	}
	s.parkLocked(c.device, c.queue)
	c.queue = nil
	s.mu.Unlock()
	close(c.done)
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
	c := &conn{
		ws: ws, device: deviceOfToken(hello.GetHello().GetSessionToken()), zones: map[string]bool{},
		wake: make(chan struct{}, 1), done: make(chan struct{}),
	}
	s.mu.Lock()
	s.frames = append(s.frames, b)
	s.all = append(s.all, c)
	s.conns[c.device] = c // replaces an older socket of the device
	if held := s.pending[c.device]; len(held) > 0 {
		delete(s.pending, c.device)
		c.enqueueLocked(held...)
	}
	s.mu.Unlock()
	go s.writeLoop(c)
	defer s.end(c)
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
			s.lastDevice = c.device
		}
		answer := &relayv1.Response{Id: req.GetId(), Result: &relayv1.Response_Ok{Ok: &relayv1.Ok{}}}
		if s.isHub(c.device) && !s.vouched(c.device) && !unvouchedAllowed(req) {
			// The gate holds on a socket opened while the hub was vouched.
			answer = errResp(relayv1.ErrorCode_ERROR_CODE_HUB_NOT_VOUCHED)
			answer.Id = req.GetId()
		}
		s.mu.Unlock()
		out, _ := proto.Marshal(&relayv1.Frame{Kind: &relayv1.Frame_Response{Response: answer}})
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
