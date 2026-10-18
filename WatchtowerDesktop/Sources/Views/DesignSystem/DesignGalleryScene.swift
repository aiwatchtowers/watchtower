import SwiftUI

/// The Design Gallery window. `SceneBuilder` has no `if` on macOS 14, so the
/// scene is always declared but is dev-only in effect: it is out of the Window
/// menu, nothing opens it outside a dev build (the Help item is gated), and
/// its content is empty unless `DevBuild.isEnabled`.
struct DesignGalleryScene: Scene {
    var body: some Scene {
        Window("Design Gallery", id: DesignSystemGallery.sceneID) {
            if DevBuild.isEnabled {
                DesignSystemGallery()
            }
        }
        .defaultSize(width: 900, height: 700)
        .commandsRemoved()
    }
}
