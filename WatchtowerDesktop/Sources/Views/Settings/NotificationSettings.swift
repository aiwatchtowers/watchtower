import SwiftUI
import UserNotifications
import WatchtowerCore

struct NotificationSettings: View {
    @AppStorage("notifyDecisions") private var notifyDecisions = true
    @AppStorage(NotificationPreferences.briefingKey) private var notifyBriefing = true
    @AppStorage(WorkbenchNotificationCenter.enabledKey) private var notifyWorkbenches = true
    @AppStorage(PlanUsageNoticePolicy.enabledKey) private var notifyPlanUsage = true
    @AppStorage(NotificationPreferences.pausedKey) private var paused = false
    @AppStorage("transcription.voiceRecognition") private var voiceRecognition = true
    @AppStorage("transcription.voiceNotifications") private var notifyUnknownVoices = true
    @AppStorage(MeetingReminderCenter.remindersEnabledKey) private var notifyMeetingReminders = true
    @AppStorage(MeetingReminderCenter.reminderMinutesKey) private var reminderMinutes = MeetingReminderCenter.defaultReminderMinutes
    @State private var testSent = false
    @State private var permissionStatus: UNAuthorizationStatus?

    var body: some View {
        Group {
            if permissionStatus == .denied {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Notifications are disabled in System Settings.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }

            Section("Notifications") {
                Toggle("Pause notifications", isOn: $paused)
                    .help("Silences every Watchtower notification until you turn this off")
                Toggle("Decision notifications", isOn: $notifyDecisions)
                Toggle("Briefing notifications", isOn: $notifyBriefing)
                    .help("Tells you when a new briefing is ready")
                Toggle("Workbench notifications", isOn: $notifyWorkbenches)
                    .help("Agent questions and asks, finished targets, proposals awaiting approval")
                Toggle("Claude plan limits", isOn: $notifyPlanUsage)
                    .help("Warns when a session or weekly limit will be hit before it resets, and at 90%")
                Toggle("Notify about unknown voices", isOn: $notifyUnknownVoices)
                    .disabled(!voiceRecognition)
                    .help("Get a notification when a recording has voices to label "
                        + "(needs Voice recognition in Settings → Meetings).")
                Toggle("Meeting reminders", isOn: $notifyMeetingReminders)
                Stepper(value: $reminderMinutes, in: 0...60) {
                    HStack {
                        Text("Remind before meeting")
                        Spacer()
                        Text(reminderMinutes == 0 ? "Off" : "\(reminderMinutes) min")
                            .foregroundStyle(.secondary)
                    }
                }
                // Not disabled with the toggle: the minutes window also
                // drives the in-app banner, which the toggle does not gate.

                // Owner decision: the stop-recording safety push is always
                // on — neither the toggle above nor "Off" minutes silence
                // it; only Pause notifications (and the OS permission) do.
                Text("The \u{201C}meeting ended — still recording\u{201D} alert is always on and is silenced only by Pause notifications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Test") {
                HStack {
                    Button("Send Test Notification") {
                        Task {
                            let granted = await NotificationService.shared.requestPermission()
                            if !granted {
                                await checkPermission()
                                return
                            }
                            NotificationService.shared.sendTestNotification()
                            testSent = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                testSent = false
                            }
                        }
                    }

                    if testSent {
                        Text("Sent!")
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                }
            }
        }
        .onAppear {
            Task { await checkPermission() }
        }
    }

    private func checkPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        permissionStatus = settings.authorizationStatus
    }
}
