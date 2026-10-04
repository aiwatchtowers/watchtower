import SwiftUI
import WatchtowerCore

/// The assistant-language controls. Every one edits a `digest.language`
/// value (an English language name) through a binding — writing it to the
/// config is the caller's job (Settings' Save bar, onboarding's Continue).
enum AssistantLanguageText {
    static let caption = "Catch-Up, briefings, tracks and digests are written in this language. "
        + "In chat, the assistant replies in the language you write in."
}

/// Onboarding's Goals row: "Assistant language", what it governs, and a
/// button showing the current language ("Russian · from macOS") that opens
/// the picker sheet. Seed `selection` with
/// `AssistantLanguageCatalog.systemDefault().englishName`; "from macOS"
/// shows while the value is still that default.
struct AssistantLanguageRow: View {
    private static let macDefault = AssistantLanguageCatalog.systemDefault().englishName

    @Binding var selection: String
    @State private var showPicker = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                // The button below carries the name for VoiceOver.
                Text("Assistant language").fontWeight(.semibold)
                    .accessibilityHidden(true)
                Text(AssistantLanguageText.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button { showPicker = true } label: {
                HStack(spacing: 6) {
                    Text(selection)
                    if selection == Self.macDefault {
                        Text("· from macOS").foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 140)
            }
            .controlSize(.large)
            .accessibilityLabel("Assistant language")
            .accessibilityValue(selection == Self.macDefault ? "\(selection), from macOS" : selection)
            .accessibilityHint("Opens the language picker")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
        .sheet(isPresented: $showPicker) {
            AssistantLanguageSheet(selection: $selection)
        }
    }
}

/// Settings → General's "Assistant language" row: the current value and a
/// Change… button opening the same sheet as onboarding.
struct AssistantLanguageField: View {
    @Binding var selection: String
    @State private var showPicker = false

    var body: some View {
        LabeledContent("Assistant language") {
            HStack {
                Text(selection)
                Button("Change…") { showPicker = true }
            }
        }
        .sheet(isPresented: $showPicker) {
            AssistantLanguageSheet(selection: $selection)
        }
    }
}

/// The language picker sheet: the Mac's languages as chips, plus a search
/// over every installed language by native or English name.
struct AssistantLanguageSheet: View {
    /// Built once: walking `Locale.availableIdentifiers` is ~1000 locales.
    private static let installed = AssistantLanguageCatalog.all()

    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AssistantLanguage?
    @State private var query = ""

    private let macLanguages = AssistantLanguageCatalog.preferred()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Assistant language").font(.headline)
                Text(AssistantLanguageText.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !macLanguages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("From your Mac")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)],
                              alignment: .leading, spacing: 6) {
                        ForEach(macLanguages) { chip($0) }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Any other")
                TextField("Search languages", text: $query)
                    .textFieldStyle(.roundedBorder)
                searchResults
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.map { "Use \($0.englishName)" } ?? "Use") {
                    if let draft { selection = draft.englishName }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(draft == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            draft = AssistantLanguageCatalog.language(named: selection, in: Self.installed)
        }
    }

    private var searchResults: some View {
        let matches = AssistantLanguageCatalog.search(query, in: Self.installed)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(matches) { lang in
                    Button {
                        draft = lang
                    } label: {
                        HStack(spacing: 4) {
                            Text(lang.nativeName)
                            if lang.nativeName != lang.englishName {
                                Text("· \(lang.englishName)").foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .background(draft == lang ? Color.accentColor.opacity(0.2) : .clear)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: matches.isEmpty ? 0 : min(CGFloat(matches.count) * 26, 156))
    }

    private func chip(_ lang: AssistantLanguage) -> some View {
        let selected = draft == lang
        return Button {
            draft = lang
        } label: {
            Text(lang.nativeName)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12)))
                .overlay(Capsule().strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .help(lang.englishName)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}
