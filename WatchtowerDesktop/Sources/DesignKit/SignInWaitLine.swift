import SwiftUI

/// A browser sign-in that is waiting for the owner: a small spinner, what it
/// waits for, why Cancel may be needed, and Cancel. Every place that starts a
/// browser sign-in shows it while the wait runs, so a page that never comes
/// back (an "Access blocked" screen, a closed tab) is never a dead end. The
/// texts come from the caller's model.
public struct SignInWaitLine: View {
    let line: String
    let hint: String
    let cancelTitle: String
    let onCancel: () -> Void

    public init(line: String, hint: String, cancelTitle: String, onCancel: @escaping () -> Void) {
        self.line = line
        self.hint = hint
        self.cancelTitle = cancelTitle
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Spacing.regular) {
            ProgressView().controlSize(.small)
            SignInWaitText(line: line, hint: hint)
            Spacer(minLength: Spacing.regular)
            Button(cancelTitle, action: onCancel)
                .buttonStyle(.kitSecondary)
        }
    }
}

/// The two lines of a waiting sign-in, for a row that puts its spinner and
/// Cancel in its own trailing slot (`SignInWaitCancel`).
public struct SignInWaitText: View {
    let line: String
    let hint: String

    public init(line: String, hint: String) {
        self.line = line
        self.hint = hint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(line)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A row's trailing slot while its sign-in waits: the spinner and Cancel in
/// place of the row's Re-login.
public struct SignInWaitCancel: View {
    let cancelTitle: String
    let onCancel: () -> Void

    public init(cancelTitle: String, onCancel: @escaping () -> Void) {
        self.cancelTitle = cancelTitle
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(spacing: Spacing.compact) {
            ProgressView().controlSize(.small)
            Button(cancelTitle, action: onCancel)
                .buttonStyle(.kitSecondary)
        }
    }
}
