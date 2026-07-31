import SwiftUI
import UserNotifications

struct NotificationSettings: View {
    @AppStorage("notifyDecisions") private var notifyDecisions = true
    @AppStorage("notifyDailySummary") private var notifyDailySummary = true
    @AppStorage("quietHoursEnabled") private var quietHoursEnabled = false
    @AppStorage(MeetingReminderCenter.remindersEnabledKey) private var notifyMeetingReminders = true
    @AppStorage(MeetingReminderCenter.reminderMinutesKey) private var reminderMinutes = MeetingReminderCenter.defaultReminderMinutes
    @State private var testSent = false
    @State private var permissionStatus: UNAuthorizationStatus?

    var body: some View {
        Form {
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

            Section("Notification Types") {
                Toggle("Decision notifications", isOn: $notifyDecisions)
                Toggle("Daily summary notifications", isOn: $notifyDailySummary)
            }

            Section("Meeting Reminders") {
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
            }

            Section("Quiet Hours") {
                Toggle("Enable quiet hours", isOn: $quietHoursEnabled)
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
        .formStyle(.grouped)
        .padding()
        .onAppear {
            Task { await checkPermission() }
        }
    }

    private func checkPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        permissionStatus = settings.authorizationStatus
    }
}
