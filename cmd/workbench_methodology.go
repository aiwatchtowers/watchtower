package cmd

import (
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/workbenchmethod"
)

var workbenchMethodologyCmd = &cobra.Command{
	Use:   "methodology <id>",
	Short: "Show or set a workbench's methodology preset, ask guard and finish check (your personal settings)",
	Long: "Without a setting flag it prints the workbench's effective methodology and where each value\n" +
		"comes from: your personal setting, the folder's .watchtower/workflow.md, or the built-in default\n" +
		"(watchtower-flow, strict, on). --preset watchtower-flow|none, --ask-guard strict|soft|off and\n" +
		"--finish-check on|off set your personal value; the value file drops it, so the folder file (else\n" +
		"the default) applies; --clear drops all three. A preset change updates the folder's skills.\n" +
		"--create-file writes a commented .watchtower/workflow.md template when the folder has none (it\n" +
		"never overwrites). --json prints the effective values, their sources and the file's state and\n" +
		"exits 0 once the workbench is found; ok/error and the *_ok/*_error fields say what failed.",
	Args: cobra.ExactArgs(1),
	RunE: runWorkbenchMethodology,
}

var (
	workbenchMethodologyFlagPreset      string
	workbenchMethodologyFlagAskGuard    string
	workbenchMethodologyFlagFinishCheck string
	workbenchMethodologyFlagClear       bool
	workbenchMethodologyFlagCreateFile  bool
)

// methodologyFileValue is the flag value that drops one personal setting.
const methodologyFileValue = "file"

// methodologyFlags maps each setting flag to its frontmatter key and value.
var methodologyFlags = []struct {
	flag, key string
	value     *string
}{
	{"preset", "preset", &workbenchMethodologyFlagPreset},
	{"ask-guard", "ask_guard", &workbenchMethodologyFlagAskGuard},
	{"finish-check", "finish_check", &workbenchMethodologyFlagFinishCheck},
}

func init() {
	c := workbenchMethodologyCmd
	c.Flags().StringVar(&workbenchMethodologyFlagPreset, "preset", "", "watchtower-flow, none, or file (use the folder file)")
	c.Flags().StringVar(&workbenchMethodologyFlagAskGuard, "ask-guard", "", "strict, soft, off, or file (use the folder file)")
	c.Flags().StringVar(&workbenchMethodologyFlagFinishCheck, "finish-check", "", "on, off, or file (use the folder file)")
	c.Flags().BoolVar(&workbenchMethodologyFlagClear, "clear", false, "drop every personal setting")
	c.Flags().BoolVar(&workbenchMethodologyFlagCreateFile, "create-file", false,
		"write a commented "+workbenchmethod.FileRel+" template when the folder has none")
	c.Flags().BoolVar(&workbenchFlagJSON, "json", false, "output JSON")
	workbenchCmd.AddCommand(c)
}

// methodologyValuesJSON is one value per setting (personal: "" = not set;
// sources: default, personal or file).
type methodologyValuesJSON struct {
	Preset      string `json:"preset"`
	AskGuard    string `json:"ask_guard"`
	FinishCheck string `json:"finish_check"`
}

// methodologyFileJSON is the folder file's state: present (a refused file
// too), the reason it was ignored, the body's length in runes, and whether
// it was cut at 64 KiB.
type methodologyFileJSON struct {
	Path      string `json:"path"`
	Present   bool   `json:"present"`
	Error     string `json:"error"`
	BodyChars int    `json:"body_chars"`
	Truncated bool   `json:"truncated"`
}

// workbenchMethodologyJSON is `workbench methodology --json`, read by the
// Desktop's Agent settings (WorkbenchMethodologyState). Keys are only added.
type workbenchMethodologyJSON struct {
	ID              int64                 `json:"id"`
	OK              bool                  `json:"ok"`
	Error           string                `json:"error"`
	Personal        methodologyValuesJSON `json:"personal"`
	Effective       methodologyValuesJSON `json:"effective"`
	Sources         methodologyValuesJSON `json:"sources"`
	File            methodologyFileJSON   `json:"file"`
	FileCreated     bool                  `json:"file_created"`
	FileCreateError string                `json:"file_create_error"`
	InstallRan      bool                  `json:"install_ran"`
	InstallOK       bool                  `json:"install_ok"`
	InstallError    string                `json:"install_error"`
}

func runWorkbenchMethodology(cmd *cobra.Command, args []string) error {
	id, err := parseWorkbenchID(args[0])
	if err != nil {
		return err
	}
	changes, err := methodologyChanges(cmd)
	if err != nil {
		return err
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	p, err := database.GetWorkbench(id)
	if err != nil {
		return fmt.Errorf("workbench %d: %w", id, err)
	}
	res, stepErr := applyWorkbenchMethodology(database, p, changes, workbenchMethodologyFlagCreateFile)
	if workbenchFlagJSON {
		return writeJSON(cmd.OutOrStdout(), res)
	}
	printMethodologyReport(cmd.OutOrStdout(), res)
	return stepErr
}

// methodologyChanges is the settings the flags write, by frontmatter key ("" =
// drop the personal setting); nothing for a read. A bad value or --clear
// beside a setting flag is refused before anything is written.
func methodologyChanges(cmd *cobra.Command) (map[string]string, error) {
	changes := map[string]string{}
	for _, f := range methodologyFlags {
		if !cmd.Flags().Changed(f.flag) {
			continue
		}
		v := *f.value
		switch {
		case v == methodologyFileValue:
			v = ""
		case !workbenchmethod.Valid(f.key, v):
			return nil, fmt.Errorf("--%s must be %s or %s, not %q", f.flag,
				strings.Join(workbenchmethod.Values(f.key), ", "), methodologyFileValue, v)
		}
		changes[f.key] = v
	}
	if workbenchMethodologyFlagClear {
		if len(changes) > 0 {
			return nil, errors.New("--clear drops every setting; it cannot be combined with --preset, --ask-guard or --finish-check")
		}
		for _, f := range methodologyFlags {
			changes[f.key] = ""
		}
	}
	return changes, nil
}

// applyWorkbenchMethodology writes changes, creates the template when asked,
// and reports what applies now; the error joins every failure (each also in
// the result).
func applyWorkbenchMethodology(database *db.DB, p *db.Workbench, changes map[string]string, createFile bool) (workbenchMethodologyJSON, error) {
	res := workbenchMethodologyJSON{ID: p.ID, OK: true, InstallOK: true}
	var errs []error
	if len(changes) > 0 {
		if err := writeMethodology(database, p.ID, changes); err != nil {
			res.OK, res.Error = false, err.Error()
			errs = append(errs, err)
		}
	}
	if createFile {
		created, err := workbenchmethod.CreateTemplate(p.FolderPath)
		res.FileCreated = created
		if err != nil {
			res.FileCreateError = err.Error()
			errs = append(errs, fmt.Errorf("creating %s: %w", workbenchmethod.FileRel, err))
		}
	}
	personal, err := database.GetWorkbenchMethodology(p.ID)
	if err != nil {
		res.OK, res.Error = false, err.Error()
		return res, errors.Join(append(errs, err)...)
	}
	fillMethodology(&res, personal, workbenchmethod.Combine(personal, workbenchmethod.ReadFile(p.FolderPath)))
	return res, errors.Join(errs...)
}

// writeMethodology applies changes over the stored settings.
func writeMethodology(database *db.DB, id int64, changes map[string]string) error {
	cur, err := database.GetWorkbenchMethodology(id)
	if err != nil {
		return err
	}
	for key, v := range changes {
		switch key {
		case "preset":
			cur.Preset = v
		case "ask_guard":
			cur.AskGuard = v
		case "finish_check":
			cur.FinishCheck = v
		}
	}
	return database.SetWorkbenchMethodology(id, cur)
}

func fillMethodology(res *workbenchMethodologyJSON, personal db.WorkbenchMethodology, e workbenchmethod.Effective) {
	res.Personal = methodologyValuesJSON{Preset: personal.Preset, AskGuard: personal.AskGuard, FinishCheck: personal.FinishCheck}
	res.Effective = methodologyValuesJSON{Preset: e.Preset, AskGuard: e.AskGuard, FinishCheck: e.FinishCheck}
	res.Sources = methodologyValuesJSON{Preset: string(e.Sources.Preset), AskGuard: string(e.Sources.AskGuard),
		FinishCheck: string(e.Sources.FinishCheck)}
	res.File = methodologyFileJSON{Path: workbenchmethod.FileRel, Present: e.File.Present, BodyChars: e.File.BodyChars,
		Truncated: e.File.Truncated}
	if e.File.Err != nil {
		res.File.Error = e.File.Err.Error()
	}
}

func printMethodologyReport(w io.Writer, res workbenchMethodologyJSON) {
	fmt.Fprintf(w, "Workbench %d methodology:\n", res.ID)
	fmt.Fprintf(w, "  preset        %s (%s)\n", res.Effective.Preset, res.Sources.Preset)
	fmt.Fprintf(w, "  ask guard     %s (%s)\n", res.Effective.AskGuard, res.Sources.AskGuard)
	fmt.Fprintf(w, "  finish check  %s (%s)\n", res.Effective.FinishCheck, res.Sources.FinishCheck)
	switch {
	case res.File.Error != "":
		fmt.Fprintf(w, "  folder file   %s ignored: %s\n", res.File.Path, res.File.Error)
	case res.File.Present:
		fmt.Fprintf(w, "  folder file   %s, %d chars of rules\n", res.File.Path, res.File.BodyChars)
	default:
		fmt.Fprintf(w, "  folder file   none (%s)\n", res.File.Path)
	}
	if res.FileCreated {
		fmt.Fprintf(w, "Created %s.\n", res.File.Path)
	}
	for _, e := range []string{res.Error, res.FileCreateError, res.InstallError} {
		if e != "" {
			fmt.Fprintf(w, "Problem: %s\n", e)
		}
	}
}
