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
                List {
                    ForEach(providers.providers) { p in
                        ProviderRow(provider: p)
                            .contentShape(Rectangle())
                            .onTapGesture { startEdit(p) }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            Divider()
            HStack {
                Button { startAdd() } label: { Image(systemName: "plus") }
                Button {
                    if let sel = editing { providers.remove(id: sel.id) }
                } label: { Image(systemName: "minus") }
                .disabled(editing == nil)
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
                    LabeledField(label: "Name", value: $draft.name, prompt: "Paciolan GitLab")
                    Picker("Kind", selection: $draft.kind) {
                        ForEach(ProviderKind.allCases, id: \.self) { Text($0.titleName).tag($0) }
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
                    LabeledField(label: draft.kind.scopeLabel, value: $draft.scope,
                                 prompt: draft.kind == .github ? "your-org" : draft.kind == .bitbucket ? "your-workspace" : "")
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
