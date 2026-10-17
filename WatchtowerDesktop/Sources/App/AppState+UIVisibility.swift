extension AppState {
    /// From launch on, every visibility change reaches the pollers.
    func startUIVisibility() {
        uiVisibility.onChange = { [weak self] in self?.applyUIVisibility($0) }
        uiVisibility.start()
    }

    /// A window of the app went on or off screen (board #731): the pollers
    /// that only feed what a window shows skip their refreshes off screen
    /// and refresh once on the way back. What must run in the background is
    /// not told: the workbench notices' poll itself, the owner asks, the
    /// session agent states behind the macOS notices and the phone's lines,
    /// the mobile hub, the daemon status behind the tray, meeting reminders,
    /// recording and dictation. Also run once after the view models are
    /// built, so one built off screen starts gated.
    func applyUIVisibility(_ onScreen: Bool) {
        calendarViewModel?.setOnScreen(onScreen)
        ideasViewModel?.setOnScreen(onScreen)
        workbenchesViewModel?.setOnScreen(onScreen)
        workbenchesViewModel?.codeFiles.setOnScreen(onScreen)
    }
}
