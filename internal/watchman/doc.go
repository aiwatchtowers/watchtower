// Package watchman learns the owner's workbench decisions (what they approved,
// declined or answered, and in which situation) so a later phase can predict
// them. Phase 1 only reads and measures: it never acts, and it imports none of
// internal/hub, internal/sessionhost or internal/tools.
package watchman
