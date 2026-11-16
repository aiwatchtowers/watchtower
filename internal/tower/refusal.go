package tower

import "watchtower/internal/tower/api"

// RefusalError is a handler's refusal: the call answers refused with this
// code and sentence, written for the owner and shown by both clients as is.
type RefusalError struct {
	Code     api.RefusalCode
	Sentence string
}

func (e *RefusalError) Error() string { return string(e.Code) + ": " + e.Sentence }

// Refuse returns the error a handler (or a Write fn, to roll back) returns
// to refuse the call with code and sentence.
func Refuse(code api.RefusalCode, sentence string) error {
	return &RefusalError{Code: code, Sentence: sentence}
}
