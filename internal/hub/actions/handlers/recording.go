package handlers

import (
	"context"
	"errors"
	"log"
	"os"
	"path/filepath"
	"regexp"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/wire"
)

// Recording intake (Go hub spec §8 p. 4a, the Swift RelayProcessor's
// ingestUpload): the hub opens a phone's recording upload into the
// recordings dir only while Desktop, the transcriber, is running.
const (
	reasonWrongHub = "wrong_hub"

	// MaxRecordingAssetBytes is the phone's own cap (RecordingUploader's
	// maximumAssetBytes): a larger asset is refused before it is downloaded.
	MaxRecordingAssetBytes uint64 = 90_000_000

	MissingAudioMessage  = "The recording's audio did not reach your Mac. Send it again."
	EmptyAudioMessage    = "The recording's audio reached your Mac empty. Send it again."
	TooLargeMessage      = "This recording is over 90 MB, too large to send to your Mac."
	NotSupportedMessage  = "This host can't transcribe recordings. Your recording stays on your phone."
	HeldMessage          = "Your Mac's transcriber isn't running. The recording waits on your phone."
	recordingWriteFailed = "Your Mac could not save this recording."
)

// uploadIDRE keeps an upload id usable as a file name: the phone's UUID, with
// nothing that could leave the recordings dir.
var uploadIDRE = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)

// RecordingsDirUnder is the recordings dir of a hub state dir in phase 1: the
// test workspace's own, never the live app-support folder.
func RecordingsDirUnder(hubDir string) string { return filepath.Join(hubDir, "recordings") }

// RecordingIntake and RecordingOutcome are the processor's types (the
// processor calls IntakeRecording through Dispatcher.SetRecordings).
type (
	RecordingIntake  = actions.RecordingIntake
	RecordingOutcome = actions.RecordingOutcome
)

func recFailed(reason, message string) RecordingOutcome {
	return RecordingOutcome{Status: wire.StatusFailed, Reason: reason, Message: message}
}

// IntakeRecording applies one upload. No plaintext audio is written without
// a transcriber to take it: with the owner's recording switch off (by
// default off on a host that never had a Desktop heartbeat, protocol §9) it
// answers the final failed(not_supported); with it on, a host whose Desktop
// went quiet answers held and writes nothing. Otherwise the asset is
// size-checked, downloaded, decrypted by chunk into
// <recordings dir>/<upload_id>.m4a (0600) and queued. A failure leaves no
// file; a retried upload that is queued already is answered received again.
// Nothing here logs a name, a path or a key.
func (h *Handlers) IntakeRecording(ctx context.Context, in RecordingIntake) RecordingOutcome {
	if h.d.Store == nil || h.d.RecordingsDir == "" {
		return recFailed(actions.ReasonNotSupported, NotSupportedMessage)
	}
	if in.TargetHub != nil && *in.TargetHub != in.ThisHub {
		return recFailed(reasonWrongHub, "This recording was addressed to another Mac.")
	}
	if !uploadIDRE.MatchString(in.UploadID) {
		return recFailed(reasonInvalidParams, "This recording has no usable id.")
	}
	on, _, err := h.d.Store.Recordings()
	if err != nil {
		log.Printf("hub recording: recording switch unreadable")
		return recFailed(reasonWriteFailed, recordingWriteFailed)
	}
	if !on {
		return recFailed(actions.ReasonNotSupported, NotSupportedMessage)
	}
	fresh, _, err := h.d.Store.DesktopHost(h.d.Clock())
	if err != nil {
		log.Printf("hub recording: desktop heartbeat unreadable")
		return recFailed(reasonWriteFailed, recordingWriteFailed)
	}
	if !fresh {
		return RecordingOutcome{Status: wire.StatusHeld, Message: HeldMessage}
	}
	if done, err := h.d.Store.HasRecording(in.UploadID); err != nil {
		return recFailed(reasonWriteFailed, recordingWriteFailed)
	} else if done {
		return RecordingOutcome{Status: wire.StatusReceived}
	}
	if in.Descriptor == nil || in.Download == nil {
		return recFailed(reasonNotFound, MissingAudioMessage)
	}
	d := *in.Descriptor
	defer clear(d.Key[:]) // the asset key never outlives the intake
	switch {
	case d.Header.TotalLength == 0:
		return recFailed(reasonNotFound, EmptyAudioMessage)
	case d.Header.TotalLength > MaxRecordingAssetBytes:
		return recFailed(reasonInvalidParams, TooLargeMessage)
	}
	if err := os.MkdirAll(h.d.RecordingsDir, 0o700); err != nil {
		log.Printf("hub recording: recordings dir unavailable")
		return recFailed(reasonWriteFailed, recordingWriteFailed)
	}
	sealed := filepath.Join(h.d.RecordingsDir, "."+in.UploadID+".sealed")
	defer func() { _ = os.Remove(sealed) }()
	if err := in.Download(ctx, sealed); err != nil {
		return recFailed(reasonNotFound, MissingAudioMessage)
	}
	// The download is not capped by the transport: refuse an oversized or
	// unreadable file undecrypted (fail closed).
	st, err := os.Stat(sealed)
	if err != nil || st.Size() < 0 || uint64(st.Size()) > secure.SealedAssetLen(secure.AssetHeader{
		ChunkSize: d.Header.ChunkSize, ChunkCount: d.Header.ChunkCount,
	}) {
		return recFailed(reasonInvalidParams, TooLargeMessage)
	}
	audio := filepath.Join(h.d.RecordingsDir, in.UploadID+".m4a")
	if err := secure.DecryptAssetFile(sealed, audio, d); err != nil {
		if errors.Is(err, secure.ErrAssetTruncated) || errors.Is(err, secure.ErrOversized) ||
			errors.Is(err, secure.ErrAuthenticationFailed) || errors.Is(err, secure.ErrAssetDigestMismatch) ||
			errors.Is(err, secure.ErrAssetBadHeader) {
			return recFailed(reasonNotFound, MissingAudioMessage)
		}
		log.Printf("hub recording: audio not written")
		return recFailed(reasonWriteFailed, recordingWriteFailed)
	}
	if err := h.d.Store.QueueRecording(in.UploadID, in.Device.String(), h.d.Clock()); err != nil {
		_ = os.Remove(audio)
		log.Print("hub recording: job not queued")
		return recFailed(reasonWriteFailed, recordingWriteFailed)
	}
	return RecordingOutcome{Status: wire.StatusReceived}
}

// RecordingAudioPath is where a queued upload's audio lives.
func RecordingAudioPath(recordingsDir, uploadID string) string {
	return filepath.Join(recordingsDir, uploadID+".m4a")
}

// SweepRecordingTemps removes what a crash leaves in dirs: a partial
// plaintext (.asset-*) and a downloaded sealed file (.*.sealed). The runtime
// calls it at start for the recordings dir and the asset dir; a missing dir
// is skipped. It returns how many files went.
func SweepRecordingTemps(dirs ...string) (int, error) {
	n := 0
	var firstErr error
	for _, dir := range dirs {
		for _, pat := range []string{".asset-*", ".*.sealed"} {
			matches, err := filepath.Glob(filepath.Join(dir, pat))
			if err != nil {
				return n, err
			}
			for _, m := range matches {
				if err := os.Remove(m); err != nil {
					if firstErr == nil && !os.IsNotExist(err) {
						firstErr = err
					}
					continue
				}
				n++
			}
		}
	}
	return n, firstErr
}
