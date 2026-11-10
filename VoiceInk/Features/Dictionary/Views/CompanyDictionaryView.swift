import ForITCommon
import SwiftUI

enum CompanyDictionaryWindow {
    static let id = "company-dictionary"
}

/// A single optional company window, reachable from Dictionary or the shared profile menu.
@MainActor
struct CompanyDictionaryView: View {
    @EnvironmentObject private var connection: CompanyDictionaryConnectionModel
    @ObservedObject private var vocabulary = SharedVocabularyService.shared
    @State private var search = ""

    private var matchingTerms: [CompanyDictionarySnapshot.Term] {
        (connection.client.snapshot?.terms ?? []).filter { term in
            search.isEmpty || ([term.canonicalSpelling, term.meaning] + term.spokenForms)
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }.sorted {
            let order = $0.canonicalSpelling.localizedStandardCompare($1.canonicalSpelling)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    var body: some View {
        Form {
            Section("Company dictionary") {
                Text("Company names and spellings are maintained in ForIT Support. Your personal vocabulary stays on this Mac.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(connection.client.statusText)
                    .accessibilityIdentifier("dictate.companyDictionary.status")
                if let checkedAt = connection.client.checkedAt {
                    LabeledContent("Last checked") { Text(checkedAt, style: .relative) }
                }
                if connection.client.needsSignIn {
                    Button("Connect company dictionary", action: connection.presentSignIn)
                        .disabled(connection.client.isBusy)
                } else {
                    Button("Check now") { Task { await connection.client.refresh(force: true) } }
                        .disabled(connection.client.isBusy)
                }
                if connection.client.isBusy { ProgressView().controlSize(.small) }
            }

            if let snapshot = connection.client.snapshot {
                Section {
                    TextField("Search company names, aliases and meanings", text: $search)
                        .accessibilityLabel("Search company dictionary")
                    Text("\(snapshot.terms.count) company terms")
                        .font(.caption).foregroundStyle(.secondary)
                    if snapshot.terms.isEmpty {
                        Text("The company dictionary is empty.")
                    } else if matchingTerms.isEmpty {
                        Text("No matching company terms.")
                    }
                    ForEach(Array(matchingTerms.prefix(100)), id: \.id) { term in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(term.canonicalSpelling).textSelection(.enabled)
                            Text(term.kind.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                            if !term.spokenForms.isEmpty {
                                Text("Also spoken as: \(term.spokenForms.joined(separator: ", "))")
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            if !term.meaning.isEmpty { Text(term.meaning).textSelection(.enabled) }
                            if (try? SharedVocabularyResolver.validatedTerm(term.canonicalSpelling)) == nil {
                                Text("Available to read; too long or unsupported as a dictation hint.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if matchingTerms.count > 100 {
                        Text("Showing the first 100 matches. Search to find any company term.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Names and spellings") }
            }

            Section {
                if connection.client.snapshot != nil {
                    let coverage = vocabulary.companyCoverage
                    Text("\(coverage.includedTermCount) company spellings added to your dictation vocabulary.")
                        .accessibilityIdentifier("dictate.companyDictionary.coverage")
                    if coverage.omittedTermCount > 0 {
                        Text("\(coverage.omittedTermCount) spellings are already covered by your choices or fall outside the supported limits.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Company vocabulary currently feeds Whisper and AI cleanup. Parakeet recognition support is still being validated; connecting does not change your engine or enable cleanup.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Recognition engines use a limited subset. Your personal words and existing spelling choices take precedence.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if connection.client.isStale {
                    Text("This saved copy can be out of date while Support is unavailable. Company terms stop being used when this sign-in expires.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if connection.client.isSignedIn {
                ForITAccountSection(account: connection.client.profile?.email) {
                    connection.signOut()
                }
            }
        }
        .formStyle(.grouped)
        .task { await connection.client.refresh() }
        .sheet(isPresented: $connection.isSignInPresented) {
            VStack(spacing: 0) {
                ForITSignInGate(
                    signIn: connection.browser,
                    subtitle: "Connect your company dictionary",
                    error: connection.signInMessage ?? connection.client.message,
                    isBusy: connection.client.isBusy,
                    action: connection.signIn
                )
                Button("Cancel", action: connection.cancelSignIn)
                    .keyboardShortcut(.cancelAction)
                    .padding()
            }
            .frame(minWidth: 420, idealWidth: 480, minHeight: 480)
            .onDisappear { connection.cancelSignIn() }
        }
    }
}

@MainActor
struct CompanyDictionarySummaryView: View {
    @EnvironmentObject private var connection: CompanyDictionaryConnectionModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Company dictionary").font(.headline)
            Text(connection.client.statusText).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open company dictionary…") { openWindow(id: CompanyDictionaryWindow.id) }
        }
    }
}

struct CompanyDictionaryMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Company dictionary…") { openWindow(id: CompanyDictionaryWindow.id) }
    }
}
