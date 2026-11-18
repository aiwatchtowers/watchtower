import Foundation
import Observation

/// Settings → System → AI → Background AI's pause (#1886, spec §6.1): one consent
/// model per pause, kept after a failure so its error line stays until the
/// stored answer changes.
@MainActor
@Observable
package final class BackgroundAISettingsModel {
    /// The last pause's writer; nil until the switch is first turned off and
    /// after a pause was saved.
    package private(set) var consent: BackgroundAIConsentModel?
    /// The stored answer changed while a pause was in flight: its outcome is
    /// stale and is dropped once the call returns.
    @ObservationIgnored private var storedChangedWhileBusy = false

    package init() {}

    package var isSaving: Bool { consent?.isSaving ?? false }
    package var errorLine: String? { consent?.errorLine }

    /// `ai background pause` through a fresh model (`make` reads config.yaml
    /// as saved); `reload` re-reads the stored answer. A nil model means the
    /// file cannot be read: the re-read shows that instead of a silent no-op.
    package func pause(make: () -> BackgroundAIConsentModel?, reload: () -> Void) async {
        guard consent?.isBusy != true else { return }
        guard let model = make() else {
            consent = nil
            reload()
            return
        }
        consent = model
        storedChangedWhileBusy = false
        let saved = await model.pause()
        if saved {
            consent = nil
            reload()
        } else if storedChangedWhileBusy {
            consent = nil
        }
    }

    /// The stored answer or the file's readability changed: a shown error is
    /// obsolete. A pause in flight finishes first.
    package func storedStateChanged() {
        if consent?.isBusy == true {
            storedChangedWhileBusy = true
        } else {
            consent = nil
        }
    }
}
