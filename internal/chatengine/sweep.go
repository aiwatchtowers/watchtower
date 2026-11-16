package chatrun

import (
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"watchtower/internal/db"
)

// orphanWait bounds the wait for a killed orphan group to disappear.
const orphanWait = 5 * time.Second

// Sweep is the startup sweep (spec §4.3), run before the hub's first claim:
// the `ai session` groups a killed daemon left are killed, then every lease
// this hub holds is released, its turns' `partial` replies marked
// session_lost for the error card.
func (r *Runner) Sweep() error {
	r.sweepOrphans()
	leases, err := r.c.DB.OwnedChatLeases(db.ChatLeaseHub, r.c.HubID)
	if err != nil {
		return err
	}
	for _, l := range leases {
		if _, err := r.c.DB.MarkChatTurnSessionLost(l.ConversationID, l.TurnID); err != nil {
			return err
		}
	}
	n, err := r.c.DB.ReleaseOwnedChatLeases(db.ChatLeaseHub, r.c.HubID)
	if err != nil {
		return err
	}
	if n > 0 {
		log.Printf("chatrun: %d chat turns of an earlier run released as session_lost", n)
	}
	return nil
}

// sweepOrphans reads every process-group file left behind. A group whose
// leader still runs this conversation's `ai session` (its command line, so a
// reused id is never killed) is killed with SIGKILL and waited for; every
// file is removed.
func (r *Runner) sweepOrphans() {
	dir := r.pgidDir()
	if dir == "" {
		return
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			log.Printf("chatrun: reading the group dir failed (%s)", errClass(err))
		}
		return
	}
	killed := 0
	for _, e := range entries {
		name := e.Name()
		if !e.Type().IsRegular() || !strings.HasSuffix(name, ".pgid") {
			continue
		}
		path := filepath.Join(dir, name)
		conv, err1 := strconv.ParseInt(strings.TrimSuffix(name, ".pgid"), 10, 64)
		b, err2 := os.ReadFile(path)
		pgid, err3 := strconv.Atoi(strings.TrimSpace(string(b)))
		if err1 == nil && err2 == nil && err3 == nil && pgid > 1 && r.isChatSession(pgid, conv) {
			if err := syscall.Kill(-pgid, syscall.SIGKILL); err == nil {
				waitGroupGone(pgid)
				killed++
			}
		}
		if err := os.Remove(path); err != nil {
			log.Printf("chatrun: removing a group file failed (%s)", errClass(err))
		}
	}
	if killed > 0 {
		log.Printf("chatrun: %d chat sessions of an earlier run killed", killed)
	}
}

// isChatSession: pgid's leader runs `ai session --conversation conv`.
func (r *Runner) isChatSession(pgid int, conv int64) bool {
	args, err := r.c.procArgs(pgid)
	if err != nil {
		return false
	}
	padded := " " + strings.Join(strings.Fields(args), " ") + " "
	return strings.Contains(padded, " ai session ") &&
		strings.Contains(padded, fmt.Sprintf(" --conversation %d ", conv))
}

// psArgs is pid's command line.
func psArgs(pid int) (string, error) {
	cmd := exec.Command("ps", "-o", "args=", "-p", strconv.Itoa(pid))
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// waitGroupGone waits (bounded) until no process of the group is left.
func waitGroupGone(pgid int) {
	deadline := time.Now().Add(orphanWait)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(-pgid, 0); errors.Is(err, syscall.ESRCH) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	log.Printf("chatrun: a killed chat session group is still there after %s", orphanWait)
}
