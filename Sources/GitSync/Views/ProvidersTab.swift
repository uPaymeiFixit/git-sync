import SwiftUI

// Settings → Providers. A dynamic list of configured sync sources, replacing
// the old fixed GitLab/GitHub/Bitbucket sections. Add as many as you like
// (e.g. two GitLab instances), each with its own host/scope/token/folder.
struct ProvidersTab: View {
    @EnvironmentObject private var providers: ProviderStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var state: AppState
    @State private var editing: Provider?
    @State private var isNew = false
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if providers.providers.isEmpty {
                ContentUnavailableView {
                    Label("No providers yet", systemImage: "plus.rectangle.on.folder")
                } description: {
                    Text("Add a GitLab, GitHub, or Bitbucket source to start syncing.")
                } actions: {
                    Button("Add Provider") { startAdd() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Single-click selection is handled natively by List(selection:).
                // The earlier `.onTapGesture(count: 2)` REPLACED the List's own
                // click recognizer, which made both selection and double-click
                // fire unreliably ("sometimes it selects, sometimes it doesn't").
                // `.simultaneousGesture` runs ALONGSIDE the List's recognizer
                // instead of competing with it, so single-click selection stays
                // native and double-click reliably opens that row. The row also
                // fills the full width so the whole row is a hit target.
                List(selection: $selection) {
                    ForEach(providers.providers) { p in
                        ProviderRow(provider: p)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .tag(p.id)
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                startEdit(p)
                            })
                            .contextMenu {
                                Button("Edit…") { startEdit(p) }
                                Button("Remove", role: .destructive) {
                                    providers.remove(id: p.id)
                                    if selection == p.id { selection = nil }
                                }
                            }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            Divider()
            HStack(spacing: 2) {
                Button { startAdd() } label: { Image(systemName: "plus") }
                    .help("Add a provider")
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .help("Remove the selected provider")
                Button { editSelected() } label: { Image(systemName: "pencil") }
                    .disabled(selection == nil)
                    .help("Edit the selected provider")
                Spacer()
                Text("\(providers.providers.count) provider(s)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .sheet(item: $editing) { p in
            ProviderEditor(initial: p, isNew: isNew)
                .environmentObject(providers)
                .environmentObject(settings)
                .environmentObject(state)
        }
        // Verify each configured provider's credentials when the tab opens, so
        // the status dots are meaningful without the user opening each editor.
        .onAppear { state.testAllUntestedProviders() }
    }

    private func startAdd() {
        // No default folder — the user must pick one before saving (validation
        // rejects an empty localPath). A guessed default was more likely wrong
        // than right and added a whole "Locations" settings tab for one field.
        isNew = true
        editing = Provider(kind: .gitlab, name: "New Provider", localPath: "")
    }
    private func startEdit(_ p: Provider) { isNew = false; editing = p }

    private func editSelected() {
        guard let id = selection, let p = providers.provider(id: id) else { return }
        startEdit(p)
    }
    private func removeSelected() {
        guard let id = selection else { return }
        providers.remove(id: id)
        selection = nil
    }
}

private struct ProviderRow: View {
    let provider: Provider
    @EnvironmentObject private var state: AppState

    // The status dot now reflects whether the credentials actually connect —
    // not just whether the provider is enabled. Grey until tested; spinner
    // while testing; green/red from the last test result.
    private var status: ConnectionTestResult? { state.connectionStatus[provider.id] }
    private var testing: Bool { state.connectionTesting.contains(provider.id) }

    private var dotColor: Color {
        if !provider.enabled { return .secondary }
        guard let status else { return .secondary }   // untested
        return status.isOK ? .green : .red
    }
    private var dotHelp: String {
        if !provider.enabled { return "Disabled" }
        if testing { return "Testing…" }
        guard let status else { return "Not tested yet — open to Test Connection" }
        return status.isOK ? status.headline : "\(status.headline) — \(status.detail(for: provider.kind))"
    }

    // Hollow circle = untested (we don't know yet); filled = we have a verdict
    // (enabled-but-untested still hollow so "never checked" reads distinctly
    // from "checked, green").
    private var dotSymbol: String {
        (status == nil && provider.enabled) ? "circle" : "circle.fill"
    }

    var body: some View {
        HStack(spacing: 10) {
            if testing {
                ProgressView().controlSize(.small).frame(width: 8, height: 8)
            } else {
                Image(systemName: dotSymbol)
                    .font(.system(size: 8))
                    .foregroundStyle(dotColor)
                    .help(dotHelp)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.name).font(.body)
                Text("\(provider.kind.titleName) · \(provider.scope.isEmpty ? provider.host : provider.scope) · \(provider.localPath)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if !provider.isConfigured {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("Missing required settings")
            } else if let status, !status.isOK {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .help(status.detail(for: provider.kind))
            }
        }
        .padding(.vertical, 2)
    }
}

// Add/edit one provider. Validates the folder against the others (collision)
// before saving.
private struct ProviderEditor: View {
    @EnvironmentObject private var providers: ProviderStore
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Provider
    @State private var token: String
    @State private var validation = ProviderStore.ProviderValidation.ok
    @State private var testResult: ConnectionTestResult?
    @State private var testing = false
    let isNew: Bool

    init(initial: Provider, isNew: Bool) {
        _draft = State(initialValue: initial)
        _token = State(initialValue: "")   // loaded onAppear (Keychain)
        self.isNew = isNew
    }

    // Where to create this provider's credential. GitLab's page is
    // host-specific, so build it from the entered host; the rest are fixed.
    private var credentialURL: URL? {
        if draft.kind == .gitlab {
            let h = draft.host.trimmingCharacters(in: .whitespaces)
            return h.isEmpty ? nil : URL(string: "https://\(h)/-/user_settings/personal_access_tokens")
        }
        return draft.kind.credentialURL
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledField(label: "Name", value: $draft.name, prompt: "Work GitLab")
                    Picker("Kind", selection: $draft.kind) {
                        ForEach(ProviderKind.allCases, id: \.self) { Text($0.titleName).tag($0) }
                    }
                    .onChange(of: draft.kind) { _, newKind in
                        // GitLab has no scope; clear any stale value so it can't
                        // linger invisibly after switching away from GitHub/Bitbucket.
                        if newKind == .gitlab { draft.scope = "" }
                    }
                    Toggle("Enabled", isOn: $draft.enabled).toggleStyle(.checkbox)
                    if let e = validation.nameError {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                }
                Section("Connection") {
                    if draft.kind == .gitlab {
                        LabeledField(label: "Host", value: $draft.host, prompt: "gitlab.example.com")
                    }
                    // GitLab has no scope field: discovery lists every project
                    // you're a member of (the API can't be narrowed to a group
                    // here), so a "Group" box would be a no-op. Use per-provider
                    // skip patterns to narrow a GitLab provider instead.
                    if draft.kind != .gitlab {
                        LabeledField(label: draft.kind.scopeLabel, value: $draft.scope,
                                     prompt: draft.kind == .github ? "your-org" : "your-workspace")
                    }
                    if draft.kind == .bitbucket {
                        LabeledField(label: "Username", value: $draft.bitbucketUser, prompt: "your-username")
                    }
                    LabeledSecureField(label: draft.kind.credentialLabel,
                                       value: $token, prompt: "", generateURL: credentialURL)
                    Text(draft.kind.credentialHelp)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Include archived repos", isOn: $draft.includeArchived).toggleStyle(.checkbox)

                    // Test connection — the fix for the "silently syncs nothing"
                    // failure mode. Hits the API with these exact credentials and
                    // reports what's actually wrong (401/403/404/unreachable).
                    HStack(spacing: 8) {
                        Button {
                            runTest()
                        } label: {
                            if testing {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Test Connection")
                            }
                        }
                        .disabled(testing)
                        if let r = testResult {
                            Label(r.headline, systemImage: r.isOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(r.isOK ? Color.green : Color.red)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                    if let r = testResult, !r.isOK {
                        let d = r.detail(for: draft.kind)
                        if !d.isEmpty {
                            Text(d).font(.caption).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Section("Sync location") {
                    FolderField(value: $draft.localPath, prompt: "/Users/you/git/Provider")
                    Text("This provider's repos clone here. Must not overlap another provider's folder.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let e = validation.pathError {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                }
                Section {
                    Picker("Sync scope", selection: $draft.filterMode) {
                        ForEach(FilterMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                Section("Skip patterns") {
                    TextField("", text: $draft.skipPatterns,
                              prompt: Text("legacy-monorepo, some-group/archive/"),
                              axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                    Text("Comma-separated repo names or path prefixes to skip for THIS provider. Case-insensitive.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            // A stale "Connected" check is worse than none — clear the result
            // whenever a credential field changes so the dot always reflects
            // the values currently on screen.
            .onChange(of: token) { testResult = nil }
            .onChange(of: draft.host) { testResult = nil }
            .onChange(of: draft.scope) { testResult = nil }
            .onChange(of: draft.bitbucketUser) { testResult = nil }
            .onChange(of: draft.kind) { testResult = nil }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
        .onAppear {
            token = providers.token(for: draft)
            // Restore the last known connection result for an existing provider
            // so reopening the editor shows its current status.
            if !isNew { testResult = state.connectionStatus[draft.id] }
        }
    }

    private func save() {
        let v = state.saveProvider(draft, token: token)
        validation = v
        guard v.isValid else { return }
        dismiss()
    }

    // Run the authenticated probe off the main thread (it's a blocking network
    // call), then publish the result back on the main actor for the UI.
    private func runTest() {
        testing = true
        testResult = nil
        let kind = draft.kind
        let host = draft.host
        let scope = draft.scope
        let user = draft.bitbucketUser
        let secret = token
        let archived = draft.includeArchived
        let id = draft.id
        Task.detached {
            let result = ConnectionTester.test(
                kind: kind, host: host, scope: scope,
                bitbucketUser: user, token: secret, includeArchived: archived)
            await MainActor.run {
                testResult = result
                testing = false
                // Mirror into AppState so the list's status dot reflects this
                // test once the editor closes (matches what the user just saw).
                state.connectionStatus[id] = result
            }
        }
    }
}
