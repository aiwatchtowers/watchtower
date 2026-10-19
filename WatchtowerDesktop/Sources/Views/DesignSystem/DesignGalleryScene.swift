import SwiftUI

/// The Design Gallery window. `SceneBuilder` has no `if` on macOS 14, so the
/// scene is always declared and the dev gate sits in its content: outside a
/// dev build the window closes itself the moment it appears, so a release
/// never shows it. The only opener is the Help menu item, which is gated too.
/// `.commandsRemoved()` is applied to drop the scene's own menu commands; the
/// SDK interface carries no documentation saying whether it also removes the
/// Window-menu item, so nothing here relies on that.
struct DesignGalleryScene: Scene {
    var body: some Scene {
        Window("Design Gallery", id: DesignSystemGallery.sceneID) {
            GalleryWindowContent()
        }
        .defaultSize(width: 900, height: 700)
        .commandsRemoved()
    }
}

private struct GalleryWindowContent: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if DevBuild.isEnabled {
            DesignSystemGallery()
        } else {
            Color.clear.onAppear { dismissWindow(id: DesignSystemGallery.sceneID) }
        }
    }
}
