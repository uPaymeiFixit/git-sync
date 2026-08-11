import SwiftUI

// Settings → Providers. A dynamic list of configured sync sources, replacing
// the old fixed GitLab/GitHub/Bitbucket sections. Add as many as you like
// (e.g. two GitLab instances), each with its own host/scope/token/folder.
struct ProvidersTab: View {
    @EnvironmentObject private var providers: ProviderStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var state: AppState
    @State private var selection: UUID?
    // ONE sheet state for both the editor and the removal confirmation. Two
    // separate `.sheet(item:)` modifiers on the same view is a SwiftUI
    // coin-flip — the second is liable to be ignored — so the cases share a
    // single presentation.
    @State private var sheet: ProviderSheet?
    @State private var removalSummary: String?

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
                // Rows carry NO gesture and NO per-row context menu. Selection,
                // double-click, and the menu all come from
                // .contextMenu(forSelectionType:menu:primaryAction:) below —
                // the API built for this, where primaryAction IS double-click.
                // The Repositories list already used this modifier, which is
                // precisely why its rows never needed a gesture and its
                // selection has always felt instant.
                //
                // Three earlier attempts here failed, all for one reason: a
                // SwiftUI tap gesture on a row and the AppKit table view's own
                // click handling cannot share a click.
                //   1. .onTapGesture(count: 2) alone — the gesture claimed the
                //      mouse-down, so single-click mostly didn't select.
                //   2. .simultaneousGesture — no better; that modifier governs
                //      composition with other SwiftUI gestures only, not with
                //      the AppKit view underneath.
                //   3. An explicit 1-count gesture next to the 2-count —
                //      reliable, but registering both counts makes SwiftUI wait
                //      out the system double-click interval before it can call a
                //      click single. Correct highlight, ~500ms late.
                // A fourth attempt via NSClickGestureRecognizer failed too:
                // NSTableView consumes mouse events in its own tracking loop
                // inside mouseDown:, so a recognizer on a descendant view never
                // sees the second click.
                List(selection: $selection) {
                    ForEach(providers.providers) { p in
                        ProviderRow(provider: p)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .tag(p.id)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let p = provider(in: ids) {
                        Button("Edit…") { startEdit(p) }
                        Button("Remove…", role: .destructive) { sheet = .remove(p) }
                    }
                } primaryAction: { ids in
                    // Double-click. Resolved from the clicked row's id rather
                    // than `selection`, so it can't act on a stale highlight.
                    if let p = provider(in: ids) { startEdit(p) }
                }
            }

            Divider()
            HStack(spacing: 2) {
                Button { startAdd() } label: { Image(systemName: "plus") }
                    .help("Add a provider")
                // Enabled state keys off the RESOLVED provider, not just a
                // non-nil selection. Keying off `selection == nil` let the
                // button look enabled while holding an id no provider matches
                // (e.g. left over from a previous removal) — the action's own
                // guard then returned silently, so the click did nothing with no
                // explanation. Now enabled implies actionable.
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .disabled(selectedProvider == nil)
                    .help("Remove the selected provider")
                Button { editSelected() } label: { Image(systemName: "pencil") }
                    .disabled(selectedProvider == nil)
                    .help("Edit the selected provider")
                Spacer()
                Text("\(providers.providers.count) provider(s)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .sheet(item: $sheet) { active in
            switch active {
            case .edit(let p, let isNew):
                ProviderEditor(initial: p, isNew: isNew)
                    .environmentObject(providers)
                    .environmentObject(settings)
                    .environmentObject(state)
            case .remove(let p):
                ProviderRemovalSheet(provider: p, impact: state.removalImpact(for: p)) { trashClones in
                    sheet = nil
                    Task {
                        let report = await state.removeProvider(p, trashClones: trashClones)
                        if selection == p.id { selection = nil }
                        if let report, !report.trashed.isEmpty || !report.skipped.isEmpty {
                            removalSummary = report.summary
                        }
                    }
                } onCancel: {
                    sheet = nil
                }
            }
        }
        .alert(
            "Provider removed",
            isPresented: Binding(
                get: { removalSummary != nil },
                set: { if !$0 { removalSummary = nil } })
        ) {
            Button("OK") { removalSummary = nil }
        } message: {
            Text(removalSummary ?? "")
        }
        // Verify each configured provider's credentials when the tab opens, so
        // the status dots are meaningful without the user opening each editor.
        .onAppear { state.testAllUntestedProviders() }
    }

    private func startAdd() {
        // No default folder — the user must pick one before saving (validation
        // rejects an empty localPath). A guessed default was more likely wrong
        // than right and added a whole "Locations" settings tab for one field.
        sheet = .edit(Provider(kind: .gitlab, name: "New Provider", localPath: ""), isNew: true)
    }
    private func startEdit(_ p: Provider) { sheet = .edit(p, isNew: false) }

    // The selected row's provider, or nil if nothing is selected or the
    // selected id no longer matches a configured provider. Single source of
    // truth for both the toolbar's enabled state and its actions, so the two
    // can't disagree.
    private var selectedProvider: Provider? {
        guard let id = selection else { return nil }
        return providers.provider(id: id)
    }

    // The provider a context-menu / double-click selection refers to. The list
    // is single-selection, so the set holds at most one id.
    private func provider(in ids: Set<UUID>) -> Provider? {
        guard let id = ids.first else { return nil }
        return providers.provider(id: id)
    }

    private func editSelected() {
        guard let p = selectedProvider else { return }
        startEdit(p)
    }
    private func removeSelected() {
        guard let p = selectedProvider else { return }
        sheet = .remove(p)
    }
}

// The single sheet presentation for this tab. `id` distinguishes edit from
// remove for the SAME provider, so switching between them re-presents rather
// than reusing a stale sheet.
private enum ProviderSheet: Identifiable {
    case edit(Provider, isNew: Bool)
    case remove(Provider)

    var id: String {
        switch self {
        case .edit(let p, let isNew): return "edit-\(isNew)-\(p.id.uuidString)"
        case .remove(let p):          return "remove-\(p.id.uuidString)"
        }
    }
}

// Confirmation for removing a provider.
//
// Removal used to be immediate from both the − button and the context menu: one
// click deleted the provider and its Keychain token, and stranded every
// inventory row it owned, with no prompt and no undo. That is how ~1,500 dead
// rows accumulated on a machine where a provider was re-created.
//
// The two consequences are deliberately separated. The metadata (rows, sync
// history, token) always goes — keeping it helps nobody, since a re-added
// provider gets a NEW UUID and can never re-link to the old rows. The cloned
// folders are real files, so they are an explicit choice, stated as two radio
// options rather than an unmarked default, and defaulting to leaving them.
private struct ProviderRemovalSheet: View {
    let provider: Provider
    let impact: ProviderRemovalImpact
    let onRemove: (Bool) -> Void
    let onCancel: () -> Void

    @State private var trashClones = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove “\(provider.name)”?")
                .font(.headline)

            Text(metadataConsequence)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if impact.clonedCount > 0 {
                Divider()
                Text("\(impact.clonedCount.formatted()) repo(s) are cloned at \(impact.localPath):")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("", selection: $trashClones) {
                    Text("Leave them on disk").tag(false)
                    Text("Move them to the Trash").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if trashClones {
                    Text("Repos with uncommitted changes or unpushed commits are skipped "
                         + "automatically. Everything else goes to the Trash, where it can "
                         + "be restored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Remove Provider", role: .destructive) { onRemove(trashClones) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 460)
    }

    private var metadataConsequence: String {
        guard impact.repoCount > 0 else {
            return "GitSync will forget this provider and delete its saved access token."
        }
        return "GitSync will stop tracking its \(impact.repoCount.formatted()) repo(s) "
             + "and forget their sync history. Its saved access token will be deleted."
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
