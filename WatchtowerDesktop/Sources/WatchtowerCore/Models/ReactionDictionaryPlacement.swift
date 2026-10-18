/// Where the reaction dictionary is edited: Automations → Reactions while the
/// Automations tab is visible, Settings → Slack otherwise.
package enum ReactionDictionaryPlacement {
    package static func showsEditorInSettings(automationsVisible: Bool) -> Bool { !automationsVisible }
}
