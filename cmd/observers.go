package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/observers"
)

var (
	observerFlagEntity      string // "target:<id>"
	observerFlagName        string
	observerFlagInstruction string
	observerFlagDisable     bool
	observerFlagEnable      bool
	observerFlagInput       string
)

var observersCmd = &cobra.Command{
	Use:   "observers",
	Short: "Manage observers that watch entities and produce activity timelines",
}

var observersListCmd = &cobra.Command{
	Use:   "list",
	Short: "List observers (optionally for one entity)",
	RunE:  runObserversList,
}

var observersShowCmd = &cobra.Command{
	Use:   "show <id>",
	Short: "Show one observer and its recent events",
	Args:  cobra.ExactArgs(1),
	RunE:  runObserversShow,
}

var observersCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create an observer on an entity (--entity target:<id>)",
	RunE:  runObserversCreate,
}

var observersEditCmd = &cobra.Command{
	Use:   "edit <id>",
	Short: "Edit an observer's name/instruction or toggle enabled",
	Args:  cobra.ExactArgs(1),
	RunE:  runObserversEdit,
}

var observersDeleteCmd = &cobra.Command{
	Use:   "delete <id>",
	Short: "Delete an observer (events cascade)",
	Args:  cobra.ExactArgs(1),
	RunE:  runObserversDelete,
}

var observersRunCmd = &cobra.Command{
	Use:   "run",
	Short: "Run all enabled observers once (the daemon calls this each cycle)",
	RunE:  runObserversRun,
}

var observersComposeCmd = &cobra.Command{
	Use:   "compose",
	Short: "Draft an observer name + watch instruction from a free-text request (AI)",
	RunE:  runObserversCompose,
}

func init() {
	observersListCmd.Flags().StringVar(&observerFlagEntity, "entity", "", "filter by entity, e.g. target:42")
	observersCreateCmd.Flags().StringVar(&observerFlagEntity, "entity", "", "entity to attach to, e.g. target:42")
	observersCreateCmd.Flags().StringVar(&observerFlagName, "name", "", "observer name")
	observersCreateCmd.Flags().StringVar(&observerFlagInstruction, "instruction", "", "natural-language watch instruction")
	observersEditCmd.Flags().StringVar(&observerFlagName, "name", "", "new name")
	observersEditCmd.Flags().StringVar(&observerFlagInstruction, "instruction", "", "new instruction")
	observersEditCmd.Flags().BoolVar(&observerFlagEnable, "enable", false, "enable the observer")
	observersEditCmd.Flags().BoolVar(&observerFlagDisable, "disable", false, "disable the observer")

	observersComposeCmd.Flags().StringVar(&observerFlagEntity, "entity", "", "entity to attach to, e.g. target:42")
	observersComposeCmd.Flags().StringVar(&observerFlagInput, "input", "", "free-text description of what to watch")

	observersCmd.AddCommand(observersListCmd, observersShowCmd, observersCreateCmd,
		observersEditCmd, observersDeleteCmd, observersRunCmd, observersComposeCmd)
	rootCmd.AddCommand(observersCmd)
}

func openObserverDB() (*db.DB, *config.Config, error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return nil, nil, fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return nil, nil, err
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return nil, nil, fmt.Errorf("opening database: %w", err)
	}
	return database, cfg, nil
}

func parseEntity(s string) (string, int, error) {
	if s == "" {
		return "", 0, fmt.Errorf("--entity is required, e.g. target:42")
	}
	typ, idStr, ok := strings.Cut(s, ":")
	if !ok {
		return "", 0, fmt.Errorf("invalid --entity %q (want target:<id>)", s)
	}
	if typ != "target" {
		return "", 0, fmt.Errorf("only entity type 'target' is supported")
	}
	id, err := strconv.Atoi(idStr)
	if err != nil {
		return "", 0, fmt.Errorf("invalid --entity %q (want target:<id>): %w", s, err)
	}
	return typ, id, nil
}

func runObserversList(cmd *cobra.Command, args []string) error {
	database, _, err := openObserverDB()
	if err != nil {
		return err
	}
	defer database.Close()

	var list []db.Observer
	if observerFlagEntity != "" {
		typ, id, err := parseEntity(observerFlagEntity)
		if err != nil {
			return err
		}
		list, err = database.GetObserversForEntity(typ, id)
		if err != nil {
			return err
		}
	} else {
		list, err = database.GetEnabledObservers()
		if err != nil {
			return err
		}
	}
	for _, o := range list {
		state := "on"
		if !o.Enabled {
			state = "off"
		}
		fmt.Fprintf(cmd.OutOrStdout(), "#%d [%s] %s:%d  %s\n", o.ID, state, o.EntityType, o.EntityID, o.Name)
	}
	return nil
}

func runObserversShow(cmd *cobra.Command, args []string) error {
	database, _, err := openObserverDB()
	if err != nil {
		return err
	}
	defer database.Close()
	id, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("invalid id %q: %w", args[0], err)
	}
	o, err := database.GetObserverByID(id)
	if err != nil {
		return err
	}
	events, err := database.GetObserverEventsForEntity(o.EntityType, o.EntityID, 50)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(map[string]any{"observer": o, "events": events})
}

func runObserversCreate(cmd *cobra.Command, args []string) error {
	database, _, err := openObserverDB()
	if err != nil {
		return err
	}
	defer database.Close()
	typ, id, err := parseEntity(observerFlagEntity)
	if err != nil {
		return err
	}
	name := observerFlagName
	if name == "" {
		name = "Observer"
	}
	instr := strings.TrimSpace(observerFlagInstruction)
	if instr == "" {
		return fmt.Errorf("--instruction is required")
	}
	newID, err := database.CreateObserver(db.Observer{
		EntityType: typ, EntityID: id, Name: name, Instruction: instr, Enabled: true,
	})
	if err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "created observer #%d\n", newID)
	return nil
}

func runObserversEdit(cmd *cobra.Command, args []string) error {
	database, _, err := openObserverDB()
	if err != nil {
		return err
	}
	defer database.Close()
	id, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("invalid id %q: %w", args[0], err)
	}
	o, err := database.GetObserverByID(id)
	if err != nil {
		return err
	}
	name, instr := o.Name, o.Instruction
	if observerFlagName != "" {
		name = observerFlagName
	}
	if observerFlagInstruction != "" {
		instr = observerFlagInstruction
	}
	if err := database.UpdateObserver(id, name, instr); err != nil {
		return err
	}
	if observerFlagEnable {
		if err := database.SetObserverEnabled(id, true); err != nil {
			return err
		}
	}
	if observerFlagDisable {
		if err := database.SetObserverEnabled(id, false); err != nil {
			return err
		}
	}
	fmt.Fprintf(cmd.OutOrStdout(), "updated observer #%d\n", id)
	return nil
}

func runObserversDelete(cmd *cobra.Command, args []string) error {
	database, _, err := openObserverDB()
	if err != nil {
		return err
	}
	defer database.Close()
	id, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("invalid id %q: %w", args[0], err)
	}
	if err := database.DeleteObserver(id); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "deleted observer #%d\n", id)
	return nil
}

func runObserversRun(cmd *cobra.Command, args []string) error {
	database, cfg, err := openObserverDB()
	if err != nil {
		return err
	}
	defer database.Close()
	applyProviderOverride(cfg)
	gen := cliGenerator(cfg)
	pipe := observers.New(database, gen, cfg.Digest.Language, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	n, err := pipe.Run(ctx)
	if err != nil {
		return fmt.Errorf("observers run failed: %w", err)
	}
	fmt.Fprintf(cmd.OutOrStdout(), "created %d event(s)\n", n)
	return nil
}

func runObserversCompose(cmd *cobra.Command, args []string) error {
	database, cfg, err := openObserverDB()
	if err != nil {
		return err
	}
	defer database.Close()
	_, id, err := parseEntity(observerFlagEntity)
	if err != nil {
		return err
	}
	if strings.TrimSpace(observerFlagInput) == "" {
		return fmt.Errorf("--input is required")
	}
	applyProviderOverride(cfg)
	gen := cliGenerator(cfg)
	pipe := observers.New(database, gen, cfg.Digest.Language, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	res, err := pipe.Compose(ctx, id, observerFlagInput)
	if err != nil {
		return fmt.Errorf("compose failed: %w", err)
	}
	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(res)
}
