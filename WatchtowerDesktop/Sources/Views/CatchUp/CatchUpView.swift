import SwiftUI

struct CatchUpView: View {
    @Bindable var vm: CatchUpViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if vm.isLoading {
                    ProgressView("Summarizing everything you missed…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else if let error = vm.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else if let result = vm.result {
                    content(result)
                } else {
                    emptyState
                }
            }
            .padding(20)
        }
        .navigationTitle("Catch Up")
        .onAppear { if vm.result == nil { vm.generate() } }
    }

    private var header: some View {
        HStack {
            Text("Catch Up").font(.largeTitle.bold())
            Spacer()
            Button {
                vm.generate()
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
            .disabled(vm.isLoading)
        }
    }

    @ViewBuilder
    private func content(_ result: CatchUpResult) -> some View {
        if result.counts.totalUnread == 0 {
            emptyState
        } else {
            if !result.tldr.isEmpty {
                Text(result.tldr)
                    .font(.body)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if !result.stories.isEmpty {
                Text("What you missed").font(.title2.bold())
                ForEach(result.stories) { story in
                    storyCard(story)
                }
            }

            Text("By source").font(.title2.bold()).padding(.top, 8)
            ForEach(result.sections.filter { !$0.items.isEmpty }) { section in
                sectionCard(section)
            }

            Button(role: .destructive) {
                Task { await vm.markAllRead() }
            } label: {
                Label("Mark everything read", systemImage: "checkmark.circle.fill")
            }
            .padding(.top, 8)
        }
    }

    private func storyCard(_ story: CatchUpStory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(priorityColor(story.priority)).frame(width: 8, height: 8)
                Text(story.title).font(.headline)
                if story.needsYou {
                    Text("needs you")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            Text(story.narrative).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func sectionCard(_ section: CatchUpSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(section.area.capitalized).font(.headline)
                if section.included < section.total {
                    Text("+\(section.total - section.included) not shown")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Mark read") {
                    Task { await vm.markSectionRead(section.area) }
                }
                .controlSize(.small)
            }
            ForEach(section.items) { item in
                Text("• \(item.title)").font(.subheadline)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundStyle(.green)
            Text("All caught up").font(.title3)
            Text("No unread digests, tracks, inbox, or briefings.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority {
        case "high": return .red
        case "medium": return .orange
        default: return .secondary
        }
    }
}
