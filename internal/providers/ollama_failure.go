package providers

import "strings"

// ollamaProvider is the Failure.Provider of every OpenAI-compatible HTTP
// call: plain ollama and the runtime-B loop share the one server setting.
const ollamaProvider = "ollama"

// OllamaFailure types one failed OpenAI-compatible call (Ollama, LM Studio,
// vLLM, llama.cpp) from its HTTP status and body; status 0 is an error the
// server reported inside a 200 answer. cause stays the error the owner
// reads (Failure.Error is cause's text). The body is matched only for the
// two facts a status cannot carry: a context overflow and a missing model.
// No sentence can establish Quota: a local server has no subscription.
func OllamaFailure(status int, body string, cause error) error {
	b := strings.ToLower(body)
	category := Unknown
	switch {
	case ollamaContextOverflow(b):
		category = ContextLimit
	case status == 401 || status == 403:
		category = Auth
	case status == 404 && strings.Contains(b, "model"):
		category = Model
	case status == 404:
		category = Transport // the URL is not an OpenAI-compatible endpoint
	case status == 429:
		category = RateLimit
	case status == 503 || status == 529:
		category = Overload
	case status >= 500:
		category = Transport
	case status == 0 && strings.Contains(b, "model") && strings.Contains(b, "not found"):
		category = Model
	}
	return &Failure{Provider: ollamaProvider, Category: category, Cause: cause}
}

// OllamaRequestFailure types a call that got no answer at all (the request
// failed, or the stream broke): cancellation and deadlines stay theirs, a
// network error is Transport. nil stays nil.
func OllamaRequestFailure(cause error) error {
	if cause == nil {
		return nil
	}
	return ProcessFailure(ollamaProvider, cause)
}

// ollamaContextOverflow matches the context-size refusals of the common
// OpenAI-compatible servers (Ollama, vLLM, llama.cpp, the OpenAI code).
func ollamaContextOverflow(body string) bool {
	for _, s := range []string{"context length", "context_length_exceeded", "context window", "context size"} {
		if strings.Contains(body, s) {
			return true
		}
	}
	return false
}
