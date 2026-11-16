package chatengine

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

// sweep is the startup sweep (Start runs it before the first claim): the
// `ai session` groups a killed daemon left are killed, then every lease
// the engine holds is released, its turns' `partial` replies marked
// session_lost for the error card.
func (e *Engine) sweep() error {
	e.sweepOrphans()
	leases, err := e.c.DB.OwnedChatLeases(db.ChatLeaseHub, LeaseOwnerID)
	if err != nil {
		return err
	}
	for _, l := range leases {
		if _, err := e.c.DB.MarkChatTurnSessionLost(l.ConversationID, l.TurnID); err != nil {
			return err
		}
	}
	n, err := e.c.DB.ReleaseOwnedChatLeases(db.ChatLeaseHub, LeaseOwnerID)
	if err != nil {
		return err
	}
	if n > 0 {
		log.Printf("chatengine: %d chat turns of an earlier run released as session_lost", n)
	}
	return nil
}

// sweepOrphans reads every process-group file left behind. A group whose
// leader still runs this conversation's `ai session` (its command line, so a
// reused id is never killed) is killed with SIGKILL and waited for; every
// file is removed.
func (e *Engine) sweepOrphans() {
	dir := e.pgidDir()
	if dir == "" {
		return
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			log.Printf("chatengine: reading the group dir failed (%s)", errClass(err))
		}
		return
	}
	killed := 0
	for _, de := range entries {
		name := de.Name()
		if !de.Type().IsRegular() || !strings.HasSuffix(name, ".pgid") {
			continue
		}
		path := filepath.Join(dir, name)
		conv, err1 := strconv.ParseInt(strings.TrimSuffix(name, ".pgid"), 10, 64)
		b, err2 := os.ReadFile(path)
		pgid, err3 := strconv.Atoi(strings.TrimSpace(string(b)))
		if err1 == nil && err2 == nil && err3 == nil && pgid > 1 && e.isChatSession(pgid, conv) {
			if err := syscall.Kill(-pgid, syscall.SIGKILL); err == nil {
				waitGroupGone(pgid)
				killed++
			}
		}
		if err := os.Remove(path); err != nil {
			log.Printf("chatengine: removing a group file failed (%s)", errClass(err))
		}
	}
	if killed > 0 {
		log.Printf("chatengine: %d chat sessions of an earlier run killed", killed)
	}
}

// isChatSession: pgid's leader runs `ai session --conversation conv`.
func (e *Engine) isChatSession(pgid int, conv int64) bool {
	args, err := e.c.procArgs(pgid)
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
	log.Printf("chatengine: a killed chat session group is still there after %s", orphanWait)
}
