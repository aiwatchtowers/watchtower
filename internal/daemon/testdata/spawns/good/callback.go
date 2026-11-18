package spawns

import (
	"context"

	"watchtower/internal/aiconsent"
	"watchtower/internal/chat"
	"watchtower/internal/chatengine"
)

// The title serves the owner's chat: an owner call in the daemon.
var engineConfig = chatengine.Config{
	Exe: "watchtower",
	Title: func(ctx context.Context, conv int64) error {
		_, err := chat.GenerateTitle(aiconsent.WithOwnerStarted(ctx), nil, nil, nil, conv)
		return err
	},
	Start: func(argv []string) (chatengine.Process, error) { return nil, nil },
}
