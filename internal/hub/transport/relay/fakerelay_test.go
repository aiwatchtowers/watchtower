package relay

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
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

// fakeRelay is a small op server over the copied proto: POST /v1/op, the
// WebSocket at /v1/ws (hello, subscribe, pushed events) and opaque blob URLs
// for attachments. It keeps last-version records with a per-zone counter, as
// the relay does.
type fakeRelay struct {
	*httptest.Server
	t    *testing.T
	hits atomic.Int64 // every HTTP request, the WebSocket and blobs included

	mu           sync.Mutex
	ops          []string
	reqs         []*relayv1.Request
	fail         map[string][]relayv1.ErrorCode // op → codes, one per call
	zones        map[string]*fakeZone
	blobs        map[string][]byte
	blobHeaders  []http.Header
	uploads      []*relayv1.CreateUpload
	attZone      map[string]string
	account      *relayv1.AccountState
	readers      [][]string
	subscribed   []string
	pageLimit    int
	hideLength   bool                // blob GETs stream with no Content-Length
	downloadBase string              // get_download URL base ("" = this server)
	saveOverride *relayv1.SaveResult // answered to the next save instead
	ws           *websocket.Conn
	wsReady      chan struct{}
}

type fakeZone struct {
	seq  uint64
	recs map[string]*relayv1.Record
}

func newFakeRelay(t *testing.T) *fakeRelay {
	t.Helper()
	f := &fakeRelay{
		t: t, fail: map[string][]relayv1.ErrorCode{}, zones: map[string]*fakeZone{},
		blobs: map[string][]byte{}, attZone: map[string]string{}, account: &relayv1.AccountState{},
		pageLimit: 500, wsReady: make(chan struct{}),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/op", f.serveOp)
	mux.HandleFunc("/v1/ws", f.serveWS)
	mux.HandleFunc("/blob/", f.serveBlob)
	f.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.hits.Add(1)
		mux.ServeHTTP(w, r)
	}))
	t.Cleanup(f.Close)
	return f
}

func opName(req *relayv1.Request) string {
	m := req.ProtoReflect()
	fd := m.WhichOneof(m.Descriptor().Oneofs().ByName("op"))
	if fd == nil {
		return ""
	}
	return string(fd.Name())
}

// failNext makes the next call of op answer code.
func (f *fakeRelay) failNext(op string, code relayv1.ErrorCode) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.fail[op] = append(f.fail[op], code)
}

func (f *fakeRelay) opsSeen() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.ops...)
}

func (f *fakeRelay) requests(op string) []*relayv1.Request {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []*relayv1.Request
	for _, r := range f.reqs {
		if opName(r) == op {
			out = append(out, r)
		}
	}
	return out
}

func (f *fakeRelay) zone(name string) *fakeZone {
	z := f.zones[name]
	if z == nil {
		z = &fakeZone{recs: map[string]*relayv1.Record{}}
		f.zones[name] = z
	}
	return z
}

// put writes a record as a phone would.
func (f *fakeRelay) put(zone, name string, env []byte) uint64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	z := f.zone(zone)
	z.seq++
	z.recs[name] = &relayv1.Record{Zone: zone, Name: name, Envelope: env, RecordSeq: z.seq, ClientModifiedAtMs: 1}
	return z.seq
}

func errResp(code relayv1.ErrorCode) *relayv1.Response {
	return &relayv1.Response{Result: &relayv1.Response_Error{Error: &relayv1.Error{Code: code, Message: "fake"}}}
}

func (f *fakeRelay) serveOp(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	var req relayv1.Request
	if err := proto.Unmarshal(body, &req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	f.mu.Lock()
	op := opName(&req)
	f.ops = append(f.ops, op)
	f.reqs = append(f.reqs, proto.Clone(&req).(*relayv1.Request))
	var resp *relayv1.Response
	if q := f.fail[op]; len(q) > 0 {
		f.fail[op] = q[1:]
		resp = errResp(q[0])
	} else {
		resp = f.handle(&req)
	}
	f.mu.Unlock()
	b, _ := proto.Marshal(resp)
	w.Header().Set("Content-Type", "application/x-protobuf")
	_, _ = w.Write(b)
}

// handle answers one op; f.mu is held.
func (f *fakeRelay) handle(req *relayv1.Request) *relayv1.Response {
	switch op := req.GetOp().(type) {
	case *relayv1.Request_Challenge:
		return &relayv1.Response{Result: &relayv1.Response_Challenge{Challenge: &relayv1.Challenge{Nonce: []byte("nonce")}}}
	case *relayv1.Request_Login:
		return &relayv1.Response{Result: &relayv1.Response_Session{Session: &relayv1.Session{Token: "tok"}}}
	case *relayv1.Request_Register:
		return &relayv1.Response{Result: &relayv1.Response_Registered{Registered: &relayv1.DeviceRegistered{
			DeviceId: client.DeviceID(op.Register.GetAuthPub())}}}
	case *relayv1.Request_Save:
		if o := f.saveOverride; o != nil {
			f.saveOverride = nil
			return &relayv1.Response{Result: &relayv1.Response_Save{Save: o}}
		}
		return f.save(op.Save)
	case *relayv1.Request_Delete:
		return f.del(op.Delete)
	case *relayv1.Request_Changes:
		return f.changes(op.Changes)
	case *relayv1.Request_SetHubReaders:
		f.readers = append(f.readers, op.SetHubReaders.GetPhoneDeviceIds())
		return &relayv1.Response{Result: &relayv1.Response_Ok{Ok: &relayv1.Ok{}}}
	case *relayv1.Request_GetAccountState:
		return &relayv1.Response{Result: &relayv1.Response_AccountState{AccountState: proto.Clone(f.account).(*relayv1.AccountState)}}
	case *relayv1.Request_CreateUpload:
		id := "att-" + strconv.Itoa(len(f.uploads)+1)
		f.uploads = append(f.uploads, op.CreateUpload)
		f.attZone[id] = op.CreateUpload.GetZone()
		return &relayv1.Response{Result: &relayv1.Response_Upload{Upload: &relayv1.Upload{
			AttachmentId: id, Url: f.URL + "/blob/" + id + "?X-Sig=opaque%2Fsig",
			Headers: map[string]string{"X-Test-Upload": "yes"},
		}}}
	case *relayv1.Request_GetDownload:
		id := op.GetDownload.GetAttachmentId()
		if f.attZone[id] != op.GetDownload.GetZone() {
			return errResp(relayv1.ErrorCode_ERROR_CODE_FORBIDDEN)
		}
		base := f.downloadBase
		if base == "" {
			base = f.URL
		}
		return &relayv1.Response{Result: &relayv1.Response_Download{Download: &relayv1.Download{Url: base + "/blob/" + id + "?X-Sig=get"}}}
	default:
		return errResp(relayv1.ErrorCode_ERROR_CODE_UNSPECIFIED)
	}
}

func live(r *relayv1.Record) bool { return r != nil && !r.GetDeleted() }

func (f *fakeRelay) save(s *relayv1.Save) *relayv1.Response {
	res := &relayv1.SaveResult{}
	for i, it := range s.GetItems() {
		rec := it.GetRecord()
		z := f.zone(rec.GetZone())
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
	}
	return &relayv1.Response{Result: &relayv1.Response_Save{Save: res}}
}

func (f *fakeRelay) del(d *relayv1.Delete) *relayv1.Response {
	res := &relayv1.DeleteResult{}
	z := f.zone(d.GetZone())
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
		}
	}
	return &relayv1.Response{Result: &relayv1.Response_Delete{Delete: res}}
}

func (f *fakeRelay) changes(c *relayv1.Changes) *relayv1.Response {
	z := f.zone(c.GetZone())
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
	if len(recs) > f.pageLimit {
		recs, res.More = recs[:f.pageLimit], true
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

func (f *fakeRelay) serveBlob(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/blob/")
	f.mu.Lock()
	defer f.mu.Unlock()
	switch r.Method {
	case http.MethodPut:
		b, _ := io.ReadAll(r.Body)
		f.blobs[id] = b
		f.blobHeaders = append(f.blobHeaders, r.Header.Clone())
	case http.MethodGet:
		b, ok := f.blobs[id]
		if !ok {
			http.NotFound(w, r)
			return
		}
		if f.hideLength {
			w.(http.Flusher).Flush() // headers out first: chunked, no Content-Length
		} else {
			w.Header().Set("Content-Length", strconv.Itoa(len(b)))
		}
		_, _ = w.Write(b)
	default:
		http.Error(w, "method", http.StatusMethodNotAllowed)
	}
}

func (f *fakeRelay) serveWS(w http.ResponseWriter, r *http.Request) {
	ws, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	ctx := context.Background()
	if _, _, err := ws.Read(ctx); err != nil { // hello
		return
	}
	ok, _ := proto.Marshal(&relayv1.Frame{Kind: &relayv1.Frame_HelloOk{HelloOk: &relayv1.HelloOk{ConnectionId: "c"}}})
	if ws.Write(ctx, websocket.MessageBinary, ok) != nil {
		return
	}
	f.mu.Lock()
	f.ws = ws
	f.mu.Unlock()
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
		f.mu.Lock()
		f.ops = append(f.ops, "ws:"+opName(req))
		f.subscribed = append(f.subscribed, req.GetSubscribe().GetZones()...)
		first := len(f.subscribed) > 0 && req.GetSubscribe() != nil
		f.mu.Unlock()
		out, _ := proto.Marshal(&relayv1.Frame{Kind: &relayv1.Frame_Response{Response: &relayv1.Response{
			Id: req.GetId(), Result: &relayv1.Response_Ok{Ok: &relayv1.Ok{}}}}})
		if ws.Write(ctx, websocket.MessageBinary, out) != nil {
			return
		}
		if first {
			select {
			case <-f.wsReady:
			default:
				close(f.wsReady)
			}
		}
	}
}

// push sends a server event on the open WebSocket.
func (f *fakeRelay) push(t *testing.T, ev *relayv1.Event) {
	t.Helper()
	select {
	case <-f.wsReady:
	case <-time.After(5 * time.Second):
		t.Fatal("no WebSocket subscribed")
	}
	f.mu.Lock()
	ws := f.ws
	f.mu.Unlock()
	b, _ := proto.Marshal(&relayv1.Frame{Kind: &relayv1.Frame_Event{Event: ev}})
	if err := ws.Write(t.Context(), websocket.MessageBinary, b); err != nil {
		t.Fatal(err)
	}
}
