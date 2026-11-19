package cmd

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"os/exec"
	"os/signal"
	"slices"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/policy"
	"watchtower/internal/slackconnect"
)

// The company connect chain (#1887 spec §3 step 2, screens §3.2): after the
// person's one Connect, each vendor of a stored company signs in in turn,
// through the company's own app. It runs inside `slack connect serve` (the
// Slack step needs the process that holds 18551; stdin company_connect,
// company_skip, company_stop) and one-shot as `watchtower company connect`.
// The bundle is stored before the chain starts (`company confirm`); a chain
// stopped part-way (Stop, the app gone, a crash) keeps what it connected, the
// rest wait in Connections, and nothing resumes on its own.

// Vendor states of a chain (company_vendor's state, company_done's states).
const (
	chainWaiting   = "waiting"
	chainConnected = "connected"
	chainCancelled = "cancelled"
	chainFailed    = "failed"
	chainSkipped   = "skipped"
)

// chainVendorOrder is the order the chain signs vendors in (spec §3 step 2).
var chainVendorOrder = []string{"slack", "google", "atlassian", "microsoft", "linear"}

// errConsentDenied is a vendor sign-in the person said no to
// (access_denied): the vendor is cancelled, the chain goes on.
var errConsentDenied = errors.New("you did not allow Watchtower")

// companyVendorEvent is one vendor's step: waiting (its sign-in is open),
// then connected (Label names the account when known), cancelled, failed
// (Message says why) or skipped (Skip, Stop, the app gone, or the policy).
type companyVendorEvent struct {
	Event   string `json:"event"`
	Flow    string `json:"flow"`
	Vendor  string `json:"vendor"`
	State   string `json:"state"`
	Label   string `json:"label"`
	Message string `json:"message"`
}

// companyDoneEvent ends a chain: each vendor it was given, by its end state.
type companyDoneEvent struct {
	Event  string            `json:"event"`
	Flow   string            `json:"flow"`
	States map[string]string `json:"states"`
}

// vendorLogin signs one vendor in through company slug and ties the account
// to it. It returns when the sign-in ends or ctx ends (Skip, Stop, the app
// gone), and reports a refused consent as errConsentDenied.
type vendorLogin func(ctx context.Context, slug string) (label string, err error)

// chainDeps are a chain's edges: one login per vendor and the policy.
type chainDeps struct {
	logins map[string]vendorLogin
	// policyAllowed is asked at each vendor's turn, so a policy that
	// changes mid-chain stops the vendors after the change.
	policyAllowed func(vendor string) bool
}

// companyChainPolicyAllowed asks the organization policy for vendor's source.
func companyChainPolicyAllowed(vendor string) bool {
	return policy.SourceAllowed(companyVendorPolicySource[vendor])
}

// companyChain is one running chain's controls; Skip may come from another
// goroutine than the chain's.
type companyChain struct {
	flow string

	mu      sync.Mutex
	current string
	skip    context.CancelFunc
}

// skipVendor ends the current vendor's wait: vendor "" is whichever vendor
// waits, another name only that vendor (a Skip that arrives after its
// vendor ended must not skip the next one). It reports whether one ended.
func (c *companyChain) skipVendor(vendor string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.skip == nil || (vendor != "" && vendor != c.current) {
		return false
	}
	c.skip()
	return true
}

func (c *companyChain) setCurrent(vendor string, skip context.CancelFunc) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.current, c.skip = vendor, skip
}

// companyChainVendors is vendors in the chain's order, each once; a name
// that is not a vendor is dropped.
func companyChainVendors(vendors []string) []string {
	var out []string
	for _, v := range chainVendorOrder {
		if slices.Contains(vendors, v) {
			out = append(out, v)
		}
	}
	return out
}

// runCompanyChain signs vendors of company slug in, one after another, in
// the chain's order, and returns each one's end state. A cancelled or failed
// vendor does not stop the chain; a vendor the policy forbids is skipped
// without a sign-in. ctx ending is Stop: the waiting vendor and every vendor
// left are skipped. emit gets each vendor's events and, last, company_done.
func runCompanyChain(ctx context.Context, d chainDeps, ch *companyChain, slug string, vendors []string, emit func(any)) map[string]string {
	states := map[string]string{}
	vendorEvent := func(vendor, state, label, msg string) {
		states[vendor] = state
		emit(companyVendorEvent{Event: "company_vendor", Flow: ch.flow, Vendor: vendor, State: state, Label: label, Message: msg})
	}
	for _, v := range companyChainVendors(vendors) {
		switch {
		case ctx.Err() != nil:
			vendorEvent(v, chainSkipped, "", "")
			continue
		case slug == "":
			// Never a sign-in without a company: --company "" is the shared app.
			vendorEvent(v, chainFailed, "", "no company was named")
			continue
		case !d.policyAllowed(v):
			vendorEvent(v, chainSkipped, "", "Blocked by your organization")
			continue
		}
		login := d.logins[v]
		if login == nil {
			vendorEvent(v, chainFailed, "", "Watchtower cannot sign in to "+v+" here")
			continue
		}
		vendorEvent(v, chainWaiting, "", "")
		vctx, skip := context.WithCancel(ctx)
		ch.setCurrent(v, skip)
		label, err := login(vctx, slug)
		ch.setCurrent("", nil)
		ended := vctx.Err() != nil
		skip()
		switch {
		case err == nil:
			vendorEvent(v, chainConnected, label, "")
		case ended:
			vendorEvent(v, chainSkipped, "", "")
		case errors.Is(err, errConsentDenied):
			vendorEvent(v, chainCancelled, "", err.Error())
		default:
			vendorEvent(v, chainFailed, "", err.Error())
		}
	}
	emit(companyDoneEvent{Event: "company_done", Flow: ch.flow, States: states})
	return states
}

// companyChainCommand is the CLI verb each non-Slack vendor's sign-in runs
// as: a child of this executable with --company <slug>, so a Skip or Stop
// ends it by killing its process group, and each keeps its own loopback
// callback, consent and account write (one code path with the Connections
// buttons).
var companyChainCommand = map[string][]string{
	"google":    {"google", "add", "--calendar", "--gmail"},
	"atlassian": {"jira", "add"},
	"microsoft": {"outlook", "login"},
	"linear":    {"linear", "add"},
}

// companyChainArgs is the child's argv (without the executable) for vendor
// through slug in cfg's workspace.
func companyChainArgs(cfg *config.Config, vendor, slug string) []string {
	args := append(slices.Clone(companyChainCommand[vendor]), "--company", slug, "--workspace", cfg.ActiveWorkspace)
	if flagConfig != "" {
		args = append(args, "--config", flagConfig)
	}
	return args
}

// companyChildWaitDelay bounds the wait for a killed child's output pipes.
const companyChildWaitDelay = 5 * time.Second

// companyChildStderrMax is how much of a child's stderr is kept for its
// failure message (the tail).
const companyChildStderrMax = 8 << 10

// execVendorLogins are the production logins of the non-Slack vendors.
func execVendorLogins(cfg *config.Config) map[string]vendorLogin {
	exe, err := os.Executable()
	if err != nil {
		exe = os.Args[0]
	}
	logins := map[string]vendorLogin{}
	for vendor := range companyChainCommand {
		logins[vendor] = func(ctx context.Context, slug string) (string, error) {
			return "", runCompanyChainChild(ctx, exe, companyChainArgs(cfg, vendor, slug))
		}
	}
	return logins
}

// runCompanyChainChild runs one vendor's sign-in child to its end. ctx
// ending kills the child's process group and reaps it; its stdout (which
// may carry an authorize URL) is dropped, the tail of its stderr becomes the
// failure message. A child stuck past a parent killed with SIGKILL ends at
// its own login timeout.
func runCompanyChainChild(ctx context.Context, exe string, args []string) error {
	c := exec.CommandContext(ctx, exe, args...)
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	c.Cancel = func() error {
		return syscall.Kill(-c.Process.Pid, syscall.SIGKILL)
	}
	c.WaitDelay = companyChildWaitDelay
	stderr := &tailWriter{max: companyChildStderrMax}
	c.Stderr = stderr
	err := c.Run()
	if err == nil {
		return nil
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return companyChildError(stderr.String())
}

// companyChildError reads a failed sign-in child's stderr: a refused consent
// is errConsentDenied, anything else its last "Error: " line (cobra's), or
// its last line.
func companyChildError(stderr string) error {
	if m := signInDeniedRE.FindStringSubmatch(stderr); m != nil && signInCancelKeys[m[1]] {
		return errConsentDenied
	}
	var errLine, lastLine string
	for line := range strings.SplitSeq(stderr, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		lastLine = line
		if msg, ok := strings.CutPrefix(line, "Error: "); ok {
			errLine = msg
		}
	}
	switch {
	case errLine != "":
		return errors.New(errLine)
	case lastLine != "":
		return errors.New(lastLine)
	}
	return errors.New("the sign-in did not finish")
}

// tailWriter keeps the last max bytes written to it.
type tailWriter struct {
	max int
	mu  sync.Mutex
	buf []byte
}

func (w *tailWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.buf = append(w.buf, p...)
	if over := len(w.buf) - w.max; over > 0 {
		w.buf = w.buf[over:]
	}
	return len(p), nil
}

func (w *tailWriter) String() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return string(w.buf)
}

// companySlackTarget is the Slack connect target of company slug's Slack
// app, tied to the company.
func companySlackTarget(workspaceDir, slug string) (slackconnect.Target, error) {
	app, err := companyApp(workspaceDir, slug, "Slack", func(b companybundle.Bundle) *companybundle.Slack { return b.Slack })
	if err != nil {
		return slackconnect.Target{}, err
	}
	t, err := slackconnect.ParseConnectInput(app.TeamID + ":" + app.ClientID)
	if err != nil {
		return slackconnect.Target{}, fmt.Errorf("company %q: its Slack app is not usable: %w", slug, err)
	}
	t.CompanySlug = slug
	return t, nil
}

// slackChainResult is how the serve loop answers a chain's Slack step.
type slackChainResult struct {
	label string
	err   error
}

// slackChainWaiters are the serve child's chain Slack flows waiting for
// their callback; the chain's goroutine adds and removes, the loop answers.
type slackChainWaiters struct {
	mu sync.Mutex
	m  map[slackconnect.FlowID]chan slackChainResult
}

func (w *slackChainWaiters) add(id slackconnect.FlowID) <-chan slackChainResult {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.m == nil {
		w.m = map[slackconnect.FlowID]chan slackChainResult{}
	}
	ch := make(chan slackChainResult, 1)
	w.m[id] = ch
	return ch
}

func (w *slackChainWaiters) remove(id slackconnect.FlowID) {
	w.mu.Lock()
	defer w.mu.Unlock()
	delete(w.m, id)
}

func (w *slackChainWaiters) get(id slackconnect.FlowID) chan slackChainResult {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.m[id]
}

// companySlackLogin is the serve child's Slack step: a flow on the serve's
// registry (no confirm: the person pressed Connect), its sign-in opened in
// the browser, and the wait for its callback, which the serve loop writes
// (writeConnectedAccount, tied to slug) and answers here. ctx ending
// cancels the flow.
func (s *slackConnectServer) companySlackLogin(ctx context.Context, slug string) (string, error) {
	t, err := companySlackTarget(s.cfg.WorkspaceDir(), slug)
	if err != nil {
		return "", err
	}
	id, err := s.reg.Begin(t, false)
	if errors.Is(err, slackconnect.ErrFlowRunning) {
		return "", errors.New("another Slack connection is in progress in Watchtower; connect Slack from Connections once it ends")
	}
	if err != nil {
		return "", fmt.Errorf("starting the Slack sign-in: %w", err)
	}
	authorizeURL, err := s.reg.BrowserURL(id)
	if err != nil {
		s.reg.Cancel(id)
		return "", fmt.Errorf("starting the Slack sign-in: %w", err)
	}
	done := s.chainWaiters.add(id)
	defer s.chainWaiters.remove(id)
	s.deps.openBrowser(authorizeURL)
	select {
	case r := <-done:
		return r.label, r.err
	case <-ctx.Done():
		s.reg.Cancel(id)
		return "", ctx.Err()
	}
}

// chainCallback ends a chain's Slack flow: a grant is written (tied to the
// company) and the page gets the write's answer; the chain learns the end.
// No Slack event goes to stdout: the chain reports the vendor itself. A
// grant whose step was skipped meanwhile is still stored (the person
// finished the sign-in); Connections shows it.
func (s *slackConnectServer) chainCallback(ev slackconnect.Event, done chan slackChainResult) error {
	res := ev.Result
	var r slackChainResult
	switch res.Outcome {
	case slackconnect.OutcomeConnected:
		_, _, err := writeConnectedAccount(s.ctx, s.cfg, s.database, ev.Target, res.Grant, s.logger.Writer())
		ev.Reply <- err
		if err != nil {
			s.logger.Printf("storing the Slack connection of chain flow %s: %v", ev.Flow, err)
		}
		r = slackChainResult{label: res.Grant.TeamName, err: err}
	case slackconnect.OutcomeDenied:
		r.err = errConsentDenied
	case slackconnect.OutcomeCancelled:
		r.err = context.Canceled
	default:
		r.err = errors.New(res.Message)
	}
	select {
	case done <- r:
	default: // the step already ended (buffered once)
	}
	return nil
}

// runningChain is the serve child's one chain; only the serve loop reads
// and writes it.
type runningChain struct {
	chain *companyChain
	stop  context.CancelFunc
	done  chan struct{}
}

// companyConnect starts a chain (stdin company_connect): one at a time, and
// never while a Slack flow holds the registry (shared guard: busy names the
// running one). It releases the company link the flow answers, so the next
// link may wait for its confirm.
func (s *slackConnectServer) companyConnect(c slackConnectCommand) error {
	if s.chain != nil {
		return s.emit(slackFlowEvent{Event: "busy", Flow: s.chain.chain.flow})
	}
	if id, live := s.reg.Live(); live {
		return s.emit(slackFlowEvent{Event: "busy", Flow: string(id)})
	}
	flow := c.Flow
	if flow == "" {
		flow = rand.Text()
	}
	s.links.release(flow)
	logins := s.deps.chainLogins
	if logins == nil {
		logins = execVendorLogins(s.cfg)
	}
	logins = withLogin(logins, "slack", s.companySlackLogin)
	ctx, stop := context.WithCancel(s.ctx)
	run := &runningChain{chain: &companyChain{flow: flow}, stop: stop, done: make(chan struct{})}
	s.chain = run
	go func() {
		defer close(run.done)
		defer stop()
		runCompanyChain(ctx, chainDeps{logins: logins, policyAllowed: companyChainPolicyAllowed}, run.chain, c.Slug, c.Vendors, s.chainEmit)
	}()
	return nil
}

// withLogin is m with key set to v, m itself untouched.
func withLogin(m map[string]vendorLogin, key string, v vendorLogin) map[string]vendorLogin {
	out := maps.Clone(m)
	if out == nil {
		out = map[string]vendorLogin{}
	}
	out[key] = v
	return out
}

// chainEmit hands a chain event to the serve loop (the only writer of
// stdout); once the loop is gone the event is dropped.
func (s *slackConnectServer) chainEmit(ev any) {
	select {
	case s.chainEvents <- ev:
	case <-s.loopGone:
	}
}

// chainControl is company_skip (vendor optional) and company_stop for the
// running chain; another flow is a no-op.
func (s *slackConnectServer) chainControl(c slackConnectCommand) {
	if s.chain == nil || s.chain.chain.flow != c.Flow {
		return
	}
	if c.Cmd == "company_stop" {
		s.chain.stop()
		return
	}
	s.chain.chain.skipVendor(c.Vendor)
}

// endChain is serve's exit: the running chain stops (its waiting sign-in is
// cancelled, a sign-in child killed and reaped) before serve returns.
func (s *slackConnectServer) endChain() {
	close(s.loopGone)
	if s.chain == nil {
		return
	}
	s.chain.stop()
	<-s.chain.done
}

// --- the one-shot `watchtower company connect` ---

var companyConnectFlags struct {
	slug    string
	vendors []string
}

var companyConnectCmd = &cobra.Command{
	Use:   "connect --slug S [--vendors slack,google,atlassian,microsoft,linear]",
	Short: "Sign in to a stored company's services one after another",
	Long: "Signs in to each service of a stored company (see 'watchtower company list') in\n" +
		"turn, through the company's own apps: Slack, Google, Atlassian, Microsoft, Linear.\n" +
		"A cancelled or failed sign-in moves on to the next. Without --vendors it signs in\n" +
		"to the company's services that have no working account yet. While the Watchtower\n" +
		"app is open it holds the Slack port: connect from Connections instead. --json\n" +
		"prints the chain's events as JSON lines (company_vendor, company_done).",
	Args: cobra.NoArgs,
	RunE: runCompanyConnect,
}

func init() {
	companyCmd.AddCommand(companyConnectCmd)
	companyConnectCmd.Flags().Bool("json", false, "print the chain's events as JSON lines")
	companyConnectCmd.Flags().StringVar(&companyConnectFlags.slug, "slug", "", "the stored company (its slug, see 'watchtower company list')")
	companyConnectCmd.Flags().StringSliceVar(&companyConnectFlags.vendors, "vendors", nil,
		"the services to sign in to (default: the company's services without a working account)")
	_ = companyConnectCmd.MarkFlagRequired("slug")
}

func runCompanyConnect(cmd *cobra.Command, _ []string) error {
	cfg, database, err := openSlackCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	ctx, stop := signal.NotifyContext(cmdContext(cmd), os.Interrupt, syscall.SIGTERM)
	defer stop()
	asJSON, _ := cmd.Flags().GetBool("json")
	vendors, err := companyConnectVendors(company.NewStore(cfg.WorkspaceDir()), database, companyConnectFlags.slug,
		companyConnectFlags.vendors, cmd.Flags().Changed("vendors"))
	if err != nil {
		return err
	}
	logins := withLogin(execVendorLogins(cfg), "slack", func(ctx context.Context, slug string) (string, error) {
		return companySlackOnce(ctx, cfg, database, newSlackConnectDeps(), slug, cmd.ErrOrStderr())
	})
	return connectCompanyOnce(ctx, chainDeps{logins: logins, policyAllowed: companyChainPolicyAllowed},
		companyConnectFlags.slug, vendors, asJSON, cmd.OutOrStdout())
}

// connectCompanyOnce runs the one-shot chain and prints it; an error when a
// vendor ended cancelled or failed.
func connectCompanyOnce(ctx context.Context, d chainDeps, slug string, vendors []string, asJSON bool, out io.Writer) error {
	var writeErr error
	emit := func(ev any) {
		if writeErr != nil {
			return
		}
		if asJSON {
			writeErr = writeSlackConnectEvent(out, ev)
			return
		}
		if v, ok := ev.(companyVendorEvent); ok && v.State != chainWaiting {
			line := v.Vendor + ": " + v.State
			if v.Label != "" {
				line += " (" + v.Label + ")"
			}
			if v.Message != "" {
				line += ": " + v.Message
			}
			_, writeErr = fmt.Fprintln(out, line)
		}
	}
	ch := &companyChain{flow: rand.Text()}
	states := runCompanyChain(ctx, d, ch, slug, vendors, emit)
	if writeErr != nil {
		return writeErr
	}
	var notConnected []string
	for _, v := range companyChainVendors(vendors) {
		if s := states[v]; s == chainCancelled || s == chainFailed {
			notConnected = append(notConnected, v)
		}
	}
	if len(notConnected) > 0 {
		return fmt.Errorf("not connected: %s; connect them later from Connections", strings.Join(notConnected, ", "))
	}
	return nil
}

// companyConnectVendors is the one-shot's vendor list: --vendors as given
// (only the company's own vendors), else the company's vendors without a
// working (ok) account. An unknown company is an error, before any sign-in.
func companyConnectVendors(store company.Store, database *db.DB, slug string, asked []string, explicit bool) ([]string, error) {
	e, ok, err := store.Get(slug, companyForcedBundle())
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, fmt.Errorf("%w %q: open your company's link or paste its code first", errUnknownCompany, slug)
	}
	has := e.Bundle.Vendors()
	if explicit {
		for _, v := range asked {
			if !slices.Contains(has, v) {
				return nil, fmt.Errorf("company %q has no %s app (it has: %s)", slug, v, strings.Join(has, ", "))
			}
		}
		return companyChainVendors(asked), nil
	}
	refs, err := database.AccountsByCompany(slug)
	if err != nil {
		return nil, err
	}
	connected := map[string]bool{}
	for _, r := range refs {
		if r.Status == "ok" {
			connected[r.Source] = true
		}
	}
	var out []string
	for _, v := range has {
		if !connected[company.VendorAccountSource[v]] {
			out = append(out, v)
		}
	}
	return out, nil
}

// companySlackOnce is the one-shot chain's Slack step: the one-shot connect
// on the company's Slack app (it binds 18551 itself), tied to the company.
func companySlackOnce(ctx context.Context, cfg *config.Config, database *db.DB, deps slackConnectDeps, slug string, errOut io.Writer) (string, error) {
	t, err := companySlackTarget(cfg.WorkspaceDir(), slug)
	if err != nil {
		return "", err
	}
	_, res, _, err := connectSlackOnce(ctx, cfg, database, deps, t, false, errOut)
	var f *slackConnectFailure
	if errors.As(err, &f) && f.reason == string(slackconnect.OutcomeDenied) {
		return "", errConsentDenied
	}
	if err != nil {
		return "", err
	}
	return res.Grant.TeamName, nil
}
