import SwiftData
import SwiftUI

@MainActor
struct SharedVocabularyView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var service = SharedVocabularyService.shared
    @State private var search = ""
    @State private var newSharedTerm = ""
    @State private var source = ""
    @State private var spelling = ""
    @State private var errorMessage = ""
    @State private var showsError = false

    private var matchingTerms: [String] {
        service.catalog.terms.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shared ForIT Vocabulary").font(.headline)
            Text("Shared terms help Whisper and AI cleanup. Other engines keep their current behavior. Your personal vocabulary above always takes precedence, including words you hide here.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(service.catalog.terms.count) shared terms · Revision \(service.catalog.revision)")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Add a shared word or phrase", text: $newSharedTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addSharedTerm)
                Button("Add Shared Term", action: addSharedTerm)
                    .disabled(newSharedTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Button("Import Update…") {
                    perform {
                        if let data = try DictionaryFilePanelService.chooseSharedVocabularyData() {
                            try service.importCatalog(data)
                        }
                    }
                }
                Button("Export Shared Terms…") {
                    perform { try DictionaryFilePanelService.saveSharedVocabularyData(service.exportCatalog()) }
                }
                Button("Reload Vocabulary") { perform { try service.reloadSharedCatalog() } }
            }
            Text("Add shared terms here or import an updated catalog to reuse with other participating apps. Reload vocabulary after another app updates it. Your personal words and spelling choices stay in Dictate.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = service.warning {
                Text(warning).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if service.omittedCount > 0 {
                Text("Some terms exceed the hint budget. Personal words are prioritized; Whisper uses a shorter subset.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Search shared terms", text: $search).textFieldStyle(.roundedBorder)
            ForEach(Array(matchingTerms.prefix(100)), id: \.self) { term in
                termRow(term)
            }
            if matchingTerms.count > 100 {
                Text("Showing the first 100 matches. Search to narrow the list.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("Personal spelling for a shared term").font(.subheadline)
            TextField("Shared term", text: $source).textFieldStyle(.roundedBorder)
            TextField("Your preferred spelling", text: $spelling).textFieldStyle(.roundedBorder)
            Button("Use Personal Spelling") {
                perform {
                    try service.setOverride(source: source, spelling: spelling)
                    source = ""
                    spelling = ""
                }
            }
            .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || spelling.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear { service.configure(context: modelContext) }
        .alert("Shared Vocabulary", isPresented: $showsError) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage) }
    }

    private func termRow(_ term: String) -> some View {
        let key = SharedVocabularyResolver.key(term)
        let override = service.preferences.overrides[key]
        return HStack(alignment: .top) {
            Toggle(isOn: Binding(
                get: { !service.preferences.suppressed.contains(key) },
                set: { enabled in perform { try service.setSuppressed(!enabled, term: term) } }
            )) {
                VStack(alignment: .leading) {
                    Text(term)
                    if let override { Text(override).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .accessibilityLabel("Include shared term \(term)")
            Spacer()
            Button("Change Spelling") {
                source = term
                spelling = override ?? term
            }
            .accessibilityLabel("Change spelling for \(term)")
            if override != nil {
                Button("Use Shared Spelling") { perform { try service.resetPersonalChoice(for: term) } }
                    .accessibilityLabel("Use shared spelling for \(term)")
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch {
            errorMessage = error.localizedDescription
            showsError = true
        }
    }

    private func addSharedTerm() {
        perform {
            try service.addSharedTerm(newSharedTerm)
            newSharedTerm = ""
        }
    }
}
