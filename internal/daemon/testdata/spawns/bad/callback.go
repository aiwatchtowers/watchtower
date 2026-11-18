package spawns

import (
	"context"

	"watchtower/internal/chat"
	"watchtower/internal/chatengine"
)

// The title callback reaches a model with no origin on its ctx.
var engineConfig = chatengine.Config{
	Exe: "watchtower",
	Title: func(ctx context.Context, conv int64) error {
		_, err := chat.GenerateTitle(ctx, nil, nil, nil, conv)
		return err
	},
}
