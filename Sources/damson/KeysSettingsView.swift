import SwiftUI

/// The "Keys" settings tab — rebind every app shortcut, disable it, or reset to
/// default. Edits go straight to `KeyBindingStore`, which persists + posts
/// `.haliteKeybindingsChanged` (rebuilding the menu live).
struct KeysSettingsTab: View {
    private let store = KeyBindingStore.shared
    /// Bumped on every store change to force a re-read (the store isn't Observable).
    @State private var version = 0

    var body: some View {
        Form {
            ForEach(AppAction.categories, id: \.self) { category in
                Section(category) {
                    ForEach(AppAction.all.filter { $0.category == category }, id: \.id) { action in
                        row(action)
                    }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Reset All to Defaults") { store.resetAll() }
                }
            }
        }
        .formStyle(.grouped)
        .id(version)
        .onReceive(NotificationCenter.default.publisher(for: .haliteKeybindingsChanged)) { _ in
            version &+= 1
        }
    }

    @ViewBuilder
    private func row(_ action: AppAction) -> some View {
        let id = action.id
        let chord = store.chord(for: id)
        let conflicts = chord.map { store.conflicts(with: $0, except: id) } ?? []

        HStack(spacing: 8) {
            Text(action.title)
            if !conflicts.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .help("Also bound to: " + conflicts.map { AppAction.find($0).title }.joined(separator: ", "))
            }
            Spacer()

            KeyRecorderField(
                chord: chord,
                isDisabled: store.isDisabled(id),
                onRecord: { store.set($0, for: id) }
            )
            .frame(width: 130, height: 22)

            Button {
                store.disable(id)
            } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .help("Disable this shortcut")
            .disabled(store.isDisabled(id))

            Button {
                store.reset(id)
            } label: { Image(systemName: "arrow.uturn.backward.circle") }
            .buttonStyle(.borderless)
            .help("Reset to default (\(action.defaultChord.display))")
            .disabled(store.isDefault(id))
        }
    }
}
