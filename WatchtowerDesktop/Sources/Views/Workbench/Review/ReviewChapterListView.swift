import SwiftUI
import WatchtowerCore

/// Deep mode's left column (board #328; big branches #1025, mockup frames 1,
/// 1b, 2b, 4a): the run's progress card, "N chapters / M files left" with
/// Next, then the map's chapters in danger order — **Breaking and
/// significant**, **Other changes**, **Can skip** (folded) — each with its
/// lane, signals, run line, danger badge and size; the current chapter opens
/// into its files. While the map loads it says so; without a map (it failed,
/// the banner above says so) or with one chapter it is the plain file list.
struct ReviewChapterListView: View {
    let model: ReviewChangesModel
    /// Sections the owner folded or opened; absent = the section's default.
    @State private var folded: [ReviewChapterList.Section.Kind: Bool] = [:]

    var body: some View {
        switch model.map {
        case .loading:
            VStack(spacing: Spacing.regular) {
                ProgressView().controlSize(.small)
                Text("Building chapters…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panelSurface()
        case .failed:
            ReviewFileListView(model: model)
        case .ready(let map):
            if ReviewChapterList.showsList(map) {
                list(map)
            } else {
                // One chapter: the file column, as a small PR has always looked (frame 3).
                ReviewFileListView(model: model)
            }
        }
    }

    private func list(_ map: ReviewMap) -> some View {
        List {
            ReviewRunCard(model: model).chapterListRow()
            counter(map).chapterListRow()
            ForEach(ReviewChapterList.sections(map)) { section in
                let shown = section.chapters.filter { chapter($0.key) != nil }
                if !shown.isEmpty {
                    sectionHeader(section, shown: shown).chapterListRow()
                    if !isFolded(section) {
                        ForEach(shown) { mapChapter in
                            if let chapter = chapter(mapChapter.key) {
                                if section.kind == .canSkip {
                                    ForEach(files(of: chapter)) { ReviewFileListView.row($0, model: model) }
                                } else {
                                    row(chapter, mapChapter, map: map).chapterListRow()
                                    if chapter.key == model.currentChapterKey {
                                        ForEach(files(of: chapter)) { ReviewFileListView.row($0, model: model, depth: 1) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .panelListStyle()
        .panelSurface()
    }

    /// The view's chapter for a map key (absent when none of its files is in this view).
    private func chapter(_ key: String) -> ReviewChapter? {
        model.chapters.first { $0.key == key }
    }

    private func files(of chapter: ReviewChapter) -> [ReviewDiffFile] {
        chapter.paths.compactMap { path in model.files.first { $0.path == path } }
    }

    private func isFolded(_ section: ReviewChapterList.Section) -> Bool {
        folded[section.kind] ?? section.foldedByDefault
    }

    /// `11 chapters / 396 files left` and Next: the next chapter in danger order.
    private func counter(_ map: ReviewMap) -> some View {
        let left = ReviewChapterList.counter(map: map) { model.isViewed($0) }
        // The next chapter after the one open: its files count as read here.
        let open = Set(map.chapters.first { $0.key == model.currentChapterKey }?.paths ?? [])
        let next = ReviewChapterList.next(map: map) { open.contains($0) || model.isViewed($0) }
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
            Text(ReviewMapPresentation.counterLine(chapters: left.chapters, files: left.files))
                .font(.caption.monospacedDigit().weight(.semibold))
            Spacer(minLength: Spacing.small)
            if let next, let title = map.chapters.first(where: { $0.key == next })?.title {
                // A failure lands in lastError.
                Button("Next: \(title) →") { Task { try? await model.selectChapter(next) } }
                    .buttonStyle(.kitQuiet)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("The next chapter not viewed yet, in danger order")
            }
        }
        .padding(.horizontal, Spacing.small)
    }

    private func sectionHeader(_ section: ReviewChapterList.Section, shown: [ReviewMap.Chapter]) -> some View {
        let isFolded = isFolded(section)
        return Button {
            withAnimation(Motion.toggle) { folded[section.kind] = !isFolded }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Image(systemName: isFolded ? "chevron.right" : "chevron.down")
                    .font(.system(size: IconSize.chevron, weight: .semibold))
                Text(section.title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(Tracking.caps)
                if section.kind == .canSkip, let skip = shown.first {
                    Text(ReviewMapPresentation.canSkipDetail(skip)).font(.caption2.monospacedDigit())
                } else {
                    Text("\(shown.count)").font(.caption2.monospacedDigit())
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, Spacing.regular)
        .padding(.horizontal, Spacing.small)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(isFolded ? "Shows the section" : "Folds the section")
    }

    private func row(_ chapter: ReviewChapter, _ mapChapter: ReviewMap.Chapter, map: ReviewMap) -> some View {
        let done = ReviewChapters.done(chapter) { model.isViewed($0) }
        let current = chapter.key == model.currentChapterKey
        let hint = ReviewMapPresentation.chapterHint(mapChapter)
        return HStack(alignment: .top, spacing: Spacing.compact) {
            // A failure lands in lastError.
            Button { Task { try? await model.toggleChapterViewed(chapter.key) } } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? Tone.success : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(done ? "Done. Mark the chapter's files not viewed" : "Mark every file of this chapter Viewed")
            .accessibilityLabel(done ? "Done" : "Not done")
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(chapter.title).fontWeight(current ? .semibold : .regular).lineLimit(1).truncationMode(.middle)
                HStack(spacing: Spacing.small) {
                    Text(ReviewMapPresentation.laneCaption(mapChapter, files: map.files)).font(.caption2.monospaced())
                    if !hint.isEmpty { Text(hint).font(.caption2) }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                ReviewChapterRunLine(model: model, key: chapter.key)
            }
            Spacer(minLength: Spacing.small)
            VStack(alignment: .trailing, spacing: Spacing.tight) {
                ReviewDangerBadge(level: mapChapter.level)
                Text(ReviewMapPresentation.lines(chapter.changedLines))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .kitRow(isSelected: current)
        .contentShape(Rectangle())
        .onTapGesture { Task { try? await model.selectChapter(chapter.key) } } // a failure lands in lastError
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
    }
}

private extension View {
    /// A row of the chapter list: no separator, no stock background, the content's own insets.
    func chapterListRow() -> some View {
        listRowInsets(EdgeInsets(top: Spacing.tight, leading: Spacing.regular, bottom: Spacing.tight, trailing: Spacing.regular))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
