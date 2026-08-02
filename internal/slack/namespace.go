package slack

import (
	"strconv"
	"strings"
)

func Namespace(accountID int64, rawID string) string {
	if rawID == "" {
		return ""
	}
	return strconv.FormatInt(accountID, 10) + ":" + rawID
}

func SplitAccountID(id string) (accountID int64, rawID string, ok bool) {
	idx := strings.IndexByte(id, ':')
	if idx <= 0 {
		return 0, id, false
	}
	n, err := strconv.ParseInt(id[:idx], 10, 64)
	if err != nil {
		return 0, id, false
	}
	return n, id[idx+1:], true
}
