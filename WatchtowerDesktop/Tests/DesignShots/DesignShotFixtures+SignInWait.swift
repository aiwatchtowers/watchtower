import AppKit
import DesignKit
import SwiftUI
@testable import WatchtowerCore
@testable import WatchtowerDesktop

/// Cancel for a browser sign-in that waits (#2132), design only: the
/// proposed states drawn with the kit's `SignInWaitLine` on fixture data
/// (`acme` / `example.com`). `docs/design/mockups/sign-in-cancel/`.
@MainActor
enum SignInWaitShotFixtures {
    enum Frame: String, CaseIterable {
        case rowIdle = "row-idle"
        case rowWaiting = "row-waiting"
        case rowTimedOut = "row-timed-out"
        case rowNarrow = "row-narrow"
        case section = "section-waiting"
        case banner = "banner-waiting"
        case calendarTop = "calendar-top-waiting"
        case companyCard = "company-card-waiting"
        case chatCard = "chat-card-waiting"
        case wizardCheck = "wizard-check-waiting"

        var size: NSSize {
            switch self {
            case .rowNarrow: NSSize(width: 420, height: 230)
            case .rowIdle, .rowWaiting, .rowTimedOut: NSSize(width: 680, height: 210)
            default: NSSize(width: 680, height: 150)
            }
        }
    }

    static var shots: [DesignShot] {
        Frame.allCases.map { frame in
            DesignShot(name: "sign-in-wait-\(frame.rawValue)", size: frame.size) {
                AnyView(view(frame)
                    .padding(Spacing.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .detailBackground())
            }
        }
    }

    @ViewBuilder
    static func view(_ frame: Frame) -> some View {
        switch frame {
        case .rowIdle: googleRows(state: .idle)
        case .rowWaiting, .rowNarrow: googleRows(state: .waiting)
        case .rowTimedOut: googleRows(state: .timedOut)
        case .section: confluenceSection
        case .banner: calendarBanner
        case .calendarTop: calendarTop
        case .companyCard: companyCard
        case .chatCard: chatCard
        case .wizardCheck: wizardCheck
        }
    }

    private enum RowState { case idle, waiting, timedOut }

    private static let copy = SignInWaitCopy.google

    private static func googleRows(state: RowState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Accounts").font(.headline).padding(.bottom, Spacing.small)
            CompanyAccountRow(title: "owner@example.com", line: "Calendar · Gmail") {
                Button("Rename…") {}.buttonStyle(.kitQuiet).disabled(state == .waiting)
                Button("Remove") {}.buttonStyle(.kitQuiet).foregroundStyle(Tone.error).disabled(state == .waiting)
            }
            CompanyAccountRow(
                title: "team@acme.example",
                line: "Calendar",
                dot: state == .waiting ? Tone.status("gray") : Tone.error,
                extra: AnyView(brokenExtra(state))
            ) {
                if state == .waiting {
                    SignInWaitCancel(cancelTitle: copy.cancelTitle) {}
                } else {
                    Button(RowStatus.Action.relogin.title) {}.buttonStyle(.kitSecondary)
                    Button("Rename…") {}.buttonStyle(.kitQuiet)
                    Button("Remove") {}.buttonStyle(.kitQuiet).foregroundStyle(Tone.error)
                }
            }
        }
    }

    @ViewBuilder
    private static func brokenExtra(_ state: RowState) -> some View {
        switch state {
        case .idle:
            Text("token expired or revoked").font(.caption).foregroundStyle(Tone.error)
        case .waiting:
            SignInWaitText(line: copy.line, hint: copy.hint)
        case .timedOut:
            Text("login timed out after 5m0s").font(.caption).foregroundStyle(Tone.error)
        }
    }

    private static var confluenceSection: some View {
        let atlassian = SignInWaitCopy.atlassian
        return VStack(alignment: .leading, spacing: Spacing.regular) {
            Text("Confluence").font(.headline)
            Text("Watchtower can read the spaces you pick. Editing needs one more permission.")
                .font(.caption).foregroundStyle(.secondary)
            SignInWaitLine(line: atlassian.line, hint: atlassian.hint, cancelTitle: atlassian.cancelTitle) {}
        }
    }

    private static var calendarBanner: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
                Text("Google Calendar for team@acme.example can't sync. Reconnect if it keeps failing.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SignInWaitLine(line: copy.line, hint: copy.hint, cancelTitle: copy.cancelTitle) {}
        }
        .padding(Spacing.cozy)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.row))
    }

    /// G4 with no single account to point at: the line on its own at the
    /// top of Calendar, above the day it shows; the empty state's Connect
    /// is disabled meanwhile.
    private static var calendarTop: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            SignInWaitLine(line: copy.line, hint: copy.hint, cancelTitle: copy.cancelTitle) {}
                .padding(Spacing.cozy)
                .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.row))
            Text("Friday, 21 November").font(.headline)
            Text("No events loaded yet.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private static var companyCard: some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: "building.2").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text("Acme").font(.headline)
                Text("Slack, Google and Atlassian through the company's apps").font(.caption).foregroundStyle(.secondary)
                SignInWaitLine(line: copy.line, hint: copy.hint, cancelTitle: copy.cancelTitle) {}
            }
        }
        .padding(Spacing.medium)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.container))
    }

    private static var chatCard: some View {
        let slack = SignInWaitCopy.slack
        return VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(spacing: Spacing.regular) {
                Image(systemName: "paperplane").foregroundStyle(.secondary)
                Text("Send to #general").font(.callout.weight(.medium))
            }
            Text("Slack needs a new sign-in to send for you.").font(.caption).foregroundStyle(Tone.error)
            SignInWaitLine(line: slack.line, hint: slack.hint, cancelTitle: slack.cancelTitle) {}
        }
        .padding(Spacing.medium)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.container))
    }

    private static var wizardCheck: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text("Check the Google app").font(.headline)
            Label("Client ID saved", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(Tone.success)
            SignInWaitLine(line: copy.line, hint: copy.hint, cancelTitle: copy.cancelTitle) {}
        }
    }
}
