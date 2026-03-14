import SwiftUI

/// Chat view for the onboarding flow — AI learns about the user.
struct OnboardingChatView: View {
    @Bindable var viewModel: OnboardingChatViewModel
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)

                Text("Tell us about yourself")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Watchtower will personalize your experience based on your role and needs.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 24)
            .padding(.bottom, 12)
            .padding(.horizontal, 40)

            Divider()

            // Chat messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if viewModel.messages.isEmpty {
                            welcomePrompts
                        }

                        ForEach(viewModel.messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }

                        if let error = viewModel.errorMessage {
                            Text(error)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) {
                    if let last = viewModel.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            // Input area
            HStack(spacing: 8) {
                ChatInput(text: $viewModel.inputText, isStreaming: viewModel.isStreaming) {
                    viewModel.send()
                }

                if canSkip {
                    Button("Continue") {
                        viewModel.finishChat()
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.trailing, 12)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    /// Show "Continue" after at least 2 user messages and no active stream.
    private var canSkip: Bool {
        let userCount = viewModel.messages.filter { $0.role == .user }.count
        return userCount >= 2 && !viewModel.isStreaming
    }

    private var welcomePrompts: some View {
        VStack(spacing: 12) {
            Text("Let's understand your role")
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .padding(.top, 20)

            if !viewModel.hasAnsweredRoleQ1 {
                // Q1: Do people report to you?
                VStack(alignment: .leading, spacing: 10) {
                    Text("Do people report to you?")
                        .font(.callout)
                        .fontWeight(.medium)

                    HStack(spacing: 8) {
                        quickButton("Yes") {
                            viewModel.recordRoleAnswer(reportsToThem: true)
                        }
                        quickButton("No") {
                            viewModel.recordRoleAnswer(reportsToThem: false)
                        }
                    }
                }
                .padding(12)
                .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            } else if !viewModel.hasAnsweredRoleQ2 {
                // Q2: Branch based on Q1 answer
                if viewModel.roleDetermination?.reportsToThem ?? false {
                    // Q2a: Do you set strategy?
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Do you determine strategy/vision for your area?")
                            .font(.callout)
                            .fontWeight(.medium)

                        HStack(spacing: 8) {
                            quickButton("Yes") {
                                viewModel.recordRoleAnswer(setStrategy: true)
                            }
                            quickButton("No") {
                                viewModel.recordRoleAnswer(setStrategy: false)
                            }
                        }
                    }
                    .padding(12)
                    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    // Q2b: Influence type
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your influence in the organization comes mainly through...")
                            .font(.callout)
                            .fontWeight(.medium)

                        HStack(spacing: 8) {
                            quickButton("Expertise & authority") {
                                viewModel.recordRoleAnswer(influenceType: "expertise")
                            }
                            quickButton("Solving tasks") {
                                viewModel.recordRoleAnswer(influenceType: "tasks")
                            }
                        }
                    }
                    .padding(12)
                    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            } else if viewModel.shouldShowRoleQ3 && !viewModel.hasAnsweredRoleQ3 {
                // Q3: Do you manage other managers? (only if Q1=yes AND Q2a=yes)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Do you manage other managers?")
                        .font(.callout)
                        .fontWeight(.medium)

                    HStack(spacing: 8) {
                        quickButton("Yes") {
                            viewModel.recordRoleAnswer(manageManagers: true)
                        }
                        quickButton("No") {
                            viewModel.recordRoleAnswer(manageManagers: false)
                        }
                    }
                }
                .padding(12)
                .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            } else {
                // Role determined, show it
                VStack(spacing: 8) {
                    Text("Your role: \(viewModel.determinedRole?.displayName ?? "Unknown")")
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    if let desc = viewModel.determinedRole?.shortDescription {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Now let's continue with your profile...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(12)
                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func quickButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.bordered)
            .controlSize(.regular)
    }

    private func quickButton(_ text: String) -> some View {
        Button(text) {
            viewModel.inputText = text
            viewModel.send()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
