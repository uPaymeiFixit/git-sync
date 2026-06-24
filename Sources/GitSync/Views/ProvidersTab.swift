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
    }

    private func startAdd() {
        let base = (settings.syncRoot as NSString).expandingTildeInPath
        isNew = true
        editing = Provider(kind: .gitlab, name: "New Provider",
                           localPath: (base as NSString).appendingPathComponent("NewProvider"))
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
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: provider.enabled ? "circle.fill" : "circle")
                .font(.system(size: 8))
                .foregroundStyle(provider.enabled ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.name).font(.body)
                Text("\(provider.kind.titleName) · \(provider.scope.isEmpty ? provider.host : provider.scope) · \(provider.localPath)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if !provider.isConfigured {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("Missing required settings")
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
    let isNew: Bool

    init(initial: Provider, isNew: Bool) {
        _draft = State(initialValue: initial)
        _token = State(initialValue: "")   // loaded onAppear (Keychain)
        self.isNew = isNew
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
                        LabeledField(label: "Username", value: $draft.bitbucketUser, prompt: "you")
                    }
                    LabeledSecureField(label: draft.kind == .bitbucket ? "App password" : "Personal access token",
                                       value: $token, prompt: "", generateURL: nil)
                    Toggle("Include archived repos", isOn: $draft.includeArchived).toggleStyle(.checkbox)
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
        .onAppear { token = providers.token(for: draft) }
    }

    private func save() {
        let v = state.saveProvider(draft, token: token)
        validation = v
        guard v.isValid else { return }
        dismiss()
    }
}
