package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/inboxfolders"
)

// The Inbox menu's folder tree (FOLDER-01). This CLI is the tree's only
// owner-facing writer: the Desktop runs it and writes no folder table. Every
// write is one compare-and-set on the tree's revision — --expect-revision is
// required and a stale one writes nothing; the CLI never retries it. Writes
// are owner verbs, refused under an AI agent's markers (AGENT-07's pattern);
// list is free. With --json a command prints one JSON object as its only
// (so last) stdout line; a refusal prints nothing on stdout, its message on
// stderr, and exits 1.

// inboxFoldersFlags holds every folders verb's flags; tests reset it.
type inboxFoldersFlags struct {
	json           bool
	title, icon    string
	parent         int64
	position       int
	hidden         bool
	expectRevision int64
	folder         int64
	newTitle       string
	newIcon        string
}

var ifFlags inboxFoldersFlags

const expectRevisionFlag = "expect-revision"

var inboxFoldersCmd = &cobra.Command{
	Use:   "folders",
	Short: "Show and arrange the Inbox menu's folders",
	Long: "Folders arrange the Inbox's artifacts. Every write needs --expect-revision (the revision\n" +
		"`list` printed) and writes nothing when the menu changed since. --json prints one JSON\n" +
		"object as the last stdout line.",
}

var inboxFoldersListCmd = &cobra.Command{
	Use:   "list",
	Short: "Show the folder tree",
	Args:  cobra.NoArgs,
	RunE:  runInboxFoldersList,
}

var inboxFoldersCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create a folder (in the Inbox root unless --parent, last unless --position)",
	Args:  cobra.NoArgs,
	RunE:  runInboxFoldersCreate,
}

var inboxFoldersUpdateCmd = &cobra.Command{
	Use:   "update <id>",
	Short: "Rename a folder, change its icon, or hide it",
	Args:  cobra.ExactArgs(1),
	RunE:  runInboxFoldersUpdate,
}

var inboxFoldersMoveCmd = &cobra.Command{
	Use:   "move <id>",
	Short: "Move a folder to another parent or position",
	Args:  cobra.ExactArgs(1),
	RunE:  runInboxFoldersMove,
}

var inboxFoldersDeleteCmd = &cobra.Command{
	Use:   "delete <id>",
	Short: "Delete a folder; its folders, automations and artifacts move to its parent",
	Args:  cobra.ExactArgs(1),
	RunE:  runInboxFoldersDelete,
}

var inboxFoldersRouteCmd = &cobra.Command{
	Use:   "route <automation-id>",
	Short: "Set the folder an automation's artifacts go to (--folder, or a new one with --new-title)",
	Args:  cobra.ExactArgs(1),
	RunE:  runInboxFoldersRoute,
}

func init() {
	inboxCmd.AddCommand(inboxFoldersCmd)
	inboxFoldersCmd.AddCommand(inboxFoldersListCmd, inboxFoldersCreateCmd, inboxFoldersUpdateCmd,
		inboxFoldersMoveCmd, inboxFoldersDeleteCmd, inboxFoldersRouteCmd)

	for _, c := range inboxFoldersCmd.Commands() {
		c.Flags().BoolVar(&ifFlags.json, "json", false, "print one JSON object as the last stdout line")
		if c != inboxFoldersListCmd {
			c.Flags().Int64Var(&ifFlags.expectRevision, expectRevisionFlag, 0,
				"the revision the change was computed against (required)")
		}
	}
	inboxFoldersCreateCmd.Flags().StringVar(&ifFlags.title, "title", "", "the folder's title (required)")
	inboxFoldersCreateCmd.Flags().StringVar(&ifFlags.icon, "icon", "", "an icon from the allowlist (empty = folder)")
	inboxFoldersCreateCmd.Flags().Int64Var(&ifFlags.parent, "parent", 0, "the parent folder's id (default the Inbox root)")
	inboxFoldersCreateCmd.Flags().IntVar(&ifFlags.position, "position", 0, "the position among its siblings (default last)")

	inboxFoldersUpdateCmd.Flags().StringVar(&ifFlags.title, "title", "", "a new title (the slug stays)")
	inboxFoldersUpdateCmd.Flags().StringVar(&ifFlags.icon, "icon", "", "a new icon from the allowlist (empty = folder)")
	inboxFoldersUpdateCmd.Flags().BoolVar(&ifFlags.hidden, "hidden", false, "hide (true) or show (false) the folder")

	inboxFoldersMoveCmd.Flags().Int64Var(&ifFlags.parent, "parent", 0, "the new parent folder's id (required)")
	inboxFoldersMoveCmd.Flags().IntVar(&ifFlags.position, "position", 0, "the position among the new siblings (required)")
	_ = inboxFoldersMoveCmd.MarkFlagRequired("parent")
	_ = inboxFoldersMoveCmd.MarkFlagRequired("position")

	inboxFoldersRouteCmd.Flags().Int64Var(&ifFlags.folder, "folder", 0, "an existing folder's id")
	inboxFoldersRouteCmd.Flags().StringVar(&ifFlags.newTitle, "new-title", "", "create a folder with this title and route to it")
	inboxFoldersRouteCmd.Flags().StringVar(&ifFlags.newIcon, "new-icon", "", "the new folder's icon (with --new-title)")
	inboxFoldersRouteCmd.Flags().Int64Var(&ifFlags.parent, "parent", 0, "the new folder's parent id (with --new-title; default the Inbox root)")
}

// inboxFolderJSON is a folder object; the keys are pinned
// (TestInboxFoldersCLI_*JSONKeys) and decoded by the Desktop.
type inboxFolderJSON struct {
	ID            int64   `json:"id"`
	Kind          string  `json:"kind"`
	Slug          string  `json:"slug"`
	Title         string  `json:"title"`
	Icon          string  `json:"icon"`
	ParentID      *int64  `json:"parent_id"`
	Position      int     `json:"position"`
	Hidden        bool    `json:"hidden"`
	AutomationIDs []int64 `json:"automation_ids"`
}

func toInboxFolderJSON(f inboxfolders.Folder) inboxFolderJSON {
	ids := f.AutomationIDs
	if ids == nil {
		ids = []int64{}
	}
	return inboxFolderJSON{ID: f.ID, Kind: f.Kind, Slug: f.Slug, Title: f.Title, Icon: f.Icon,
		ParentID: f.ParentID, Position: f.Position, Hidden: f.Hidden, AutomationIDs: ids}
}

type inboxFoldersListJSON struct {
	Revision int64             `json:"revision"`
	Folders  []inboxFolderJSON `json:"folders"`
}

type inboxFolderWriteJSON struct {
	Revision int64           `json:"revision"`
	Folder   inboxFolderJSON `json:"folder"`
}

type inboxFolderMovedJSON struct {
	Folders     int                      `json:"folders"`
	Automations int                      `json:"automations"`
	Artifacts   int                      `json:"artifacts"`
	Renamed     []inboxFolderRenamedJSON `json:"renamed"`
}

// inboxFolderRenamedJSON is a moved-up folder renamed to keep sibling titles
// unique (never nil in the output).
type inboxFolderRenamedJSON struct {
	ID   int64  `json:"id"`
	From string `json:"from"`
	To   string `json:"to"`
}

type inboxFolderDeleteJSON struct {
	Revision int64                `json:"revision"`
	Moved    inboxFolderMovedJSON `json:"moved"`
}

type inboxFolderRouteJSON struct {
	Revision     int64           `json:"revision"`
	AutomationID int64           `json:"automation_id"`
	Folder       inboxFolderJSON `json:"folder"`
	Created      bool            `json:"created"`
}

// inboxFoldersJSONLine prints v as one compact line, so it is the last stdout line.
func inboxFoldersJSONLine(w io.Writer, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(w, string(b))
	return err
}

// checkInboxFolderWrite runs a write's checks that need no database, in
// order: the agent refusal, then the required revision.
func checkInboxFolderWrite(cmd *cobra.Command) error {
	if err := refuseUnderAgent("change the Inbox menu"); err != nil {
		return err
	}
	if !cmd.Flags().Changed(expectRevisionFlag) {
		return inboxfolders.ErrRevisionRequired
	}
	return nil
}

// openInboxFolders opens the workspace database; a write waits out another
// process's write lock like any owner write.
func openInboxFolders(write bool) (*inboxfolders.Store, func(), error) {
	database, err := openDBFromConfig()
	if err != nil {
		return nil, nil, err
	}
	if write {
		if err := database.SetBusyTimeout(ownerWriteBusyTimeout); err != nil {
			database.Close()
			return nil, nil, err
		}
	}
	return inboxfolders.NewStore(database), func() { database.Close() }, nil
}

func parseInboxFolderID(what, arg string) (int64, error) {
	id, err := strconv.ParseInt(arg, 10, 64)
	if err != nil || id <= 0 {
		return 0, fmt.Errorf("invalid %s id %q", what, arg)
	}
	return id, nil
}

func runInboxFoldersList(cmd *cobra.Command, _ []string) error {
	store, closeDB, err := openInboxFolders(false)
	if err != nil {
		return err
	}
	defer closeDB()
	tree, err := store.List(cmd.Context())
	if err != nil {
		return err
	}
	out := cmd.OutOrStdout()
	if ifFlags.json {
		folders := make([]inboxFolderJSON, 0, len(tree.Folders))
		for _, f := range tree.Folders {
			folders = append(folders, toInboxFolderJSON(f))
		}
		return inboxFoldersJSONLine(out, inboxFoldersListJSON{Revision: tree.Revision, Folders: folders})
	}
	fmt.Fprintf(out, "Revision %d\n", tree.Revision)
	depth := map[int64]int{}
	for _, f := range tree.Folders {
		d := 0
		if f.ParentID != nil {
			d = depth[*f.ParentID] + 1
		}
		depth[f.ID] = d
		fmt.Fprintf(out, "%s%s  #%d %s%s\n", strings.Repeat("  ", d), f.Title, f.ID, f.Slug, folderNotes(f))
	}
	return nil
}

// folderNotes is the text list's tail for a folder: hidden, routed automations.
func folderNotes(f inboxfolders.Folder) string {
	var notes []string
	if f.Hidden {
		notes = append(notes, "hidden")
	}
	if len(f.AutomationIDs) > 0 {
		ids := make([]string, len(f.AutomationIDs))
		for i, id := range f.AutomationIDs {
			ids[i] = strconv.FormatInt(id, 10)
		}
		notes = append(notes, "automations "+strings.Join(ids, ", "))
	}
	if len(notes) == 0 {
		return ""
	}
	return "  (" + strings.Join(notes, "; ") + ")"
}

// printInboxFolderWrite prints a create/update/move result.
func printInboxFolderWrite(cmd *cobra.Command, verb string, tree inboxfolders.Tree, f inboxfolders.Folder) error {
	if ifFlags.json {
		return inboxFoldersJSONLine(cmd.OutOrStdout(), inboxFolderWriteJSON{Revision: tree.Revision, Folder: toInboxFolderJSON(f)})
	}
	fmt.Fprintf(cmd.OutOrStdout(), "%s folder #%d %q (revision %d)\n", verb, f.ID, f.Title, tree.Revision)
	return nil
}

// inboxFoldersInt64Flag is the flag's value when it was given, else nil.
func inboxFoldersInt64Flag(cmd *cobra.Command, name string, v int64) *int64 {
	if !cmd.Flags().Changed(name) {
		return nil
	}
	return &v
}

func inboxFoldersStringFlag(cmd *cobra.Command, name, v string) *string {
	if !cmd.Flags().Changed(name) {
		return nil
	}
	return &v
}

func runInboxFoldersCreate(cmd *cobra.Command, _ []string) error {
	if err := checkInboxFolderWrite(cmd); err != nil {
		return err
	}
	store, closeDB, err := openInboxFolders(true)
	if err != nil {
		return err
	}
	defer closeDB()
	req := inboxfolders.CreateRequest{Title: ifFlags.title, Icon: ifFlags.icon,
		ParentID: inboxFoldersInt64Flag(cmd, "parent", ifFlags.parent), ExpectRevision: ifFlags.expectRevision}
	if cmd.Flags().Changed("position") {
		p := ifFlags.position
		req.Position = &p
	}
	tree, f, err := store.Create(cmd.Context(), req)
	if err != nil {
		return err
	}
	return printInboxFolderWrite(cmd, "Created", tree, f)
}

func runInboxFoldersUpdate(cmd *cobra.Command, args []string) error {
	if err := checkInboxFolderWrite(cmd); err != nil {
		return err
	}
	id, err := parseInboxFolderID("folder", args[0])
	if err != nil {
		return err
	}
	store, closeDB, err := openInboxFolders(true)
	if err != nil {
		return err
	}
	defer closeDB()
	req := inboxfolders.UpdateRequest{Title: inboxFoldersStringFlag(cmd, "title", ifFlags.title),
		Icon: inboxFoldersStringFlag(cmd, "icon", ifFlags.icon), ExpectRevision: ifFlags.expectRevision}
	if cmd.Flags().Changed("hidden") {
		h := ifFlags.hidden
		req.Hidden = &h
	}
	tree, f, err := store.Update(cmd.Context(), id, req)
	if err != nil {
		return err
	}
	return printInboxFolderWrite(cmd, "Updated", tree, f)
}

func runInboxFoldersMove(cmd *cobra.Command, args []string) error {
	if err := checkInboxFolderWrite(cmd); err != nil {
		return err
	}
	id, err := parseInboxFolderID("folder", args[0])
	if err != nil {
		return err
	}
	store, closeDB, err := openInboxFolders(true)
	if err != nil {
		return err
	}
	defer closeDB()
	tree, f, err := store.Move(cmd.Context(), id, ifFlags.parent, ifFlags.position, ifFlags.expectRevision)
	if err != nil {
		return err
	}
	return printInboxFolderWrite(cmd, "Moved", tree, f)
}

func runInboxFoldersDelete(cmd *cobra.Command, args []string) error {
	if err := checkInboxFolderWrite(cmd); err != nil {
		return err
	}
	id, err := parseInboxFolderID("folder", args[0])
	if err != nil {
		return err
	}
	store, closeDB, err := openInboxFolders(true)
	if err != nil {
		return err
	}
	defer closeDB()
	tree, moved, err := store.Delete(cmd.Context(), id, ifFlags.expectRevision)
	if err != nil {
		return err
	}
	out := cmd.OutOrStdout()
	if ifFlags.json {
		renamed := make([]inboxFolderRenamedJSON, 0, len(moved.Renamed))
		for _, r := range moved.Renamed {
			renamed = append(renamed, inboxFolderRenamedJSON{ID: r.ID, From: r.From, To: r.To})
		}
		return inboxFoldersJSONLine(out, inboxFolderDeleteJSON{Revision: tree.Revision, Moved: inboxFolderMovedJSON{
			Folders: moved.Folders, Automations: moved.Automations, Artifacts: moved.Artifacts, Renamed: renamed}})
	}
	fmt.Fprintf(out, "Deleted folder #%d (revision %d): moved up %d folders, %d automations, %d artifacts\n",
		id, tree.Revision, moved.Folders, moved.Automations, moved.Artifacts)
	for _, r := range moved.Renamed {
		fmt.Fprintf(out, "Renamed folder #%d %q to %q\n", r.ID, r.From, r.To)
	}
	return nil
}

func runInboxFoldersRoute(cmd *cobra.Command, args []string) error {
	if err := checkInboxFolderWrite(cmd); err != nil {
		return err
	}
	automationID, err := parseInboxFolderID("automation", args[0])
	if err != nil {
		return err
	}
	store, closeDB, err := openInboxFolders(true)
	if err != nil {
		return err
	}
	defer closeDB()
	req := inboxfolders.RouteRequest{FolderID: inboxFoldersInt64Flag(cmd, "folder", ifFlags.folder),
		NewTitle: ifFlags.newTitle, NewIcon: ifFlags.newIcon,
		ParentID: inboxFoldersInt64Flag(cmd, "parent", ifFlags.parent), ExpectRevision: ifFlags.expectRevision}
	tree, f, created, err := store.Route(cmd.Context(), automationID, req)
	if err != nil {
		return err
	}
	out := cmd.OutOrStdout()
	if ifFlags.json {
		return inboxFoldersJSONLine(out, inboxFolderRouteJSON{Revision: tree.Revision, AutomationID: automationID,
			Folder: toInboxFolderJSON(f), Created: created})
	}
	verb := "Routed"
	if created {
		verb = "Created folder and routed"
	}
	fmt.Fprintf(out, "%s automation %d to folder #%d %q (revision %d)\n", verb, automationID, f.ID, f.Title, tree.Revision)
	return nil
}
