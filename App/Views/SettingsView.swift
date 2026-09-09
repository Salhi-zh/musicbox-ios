import SwiftUI

/// Server connection settings + manual sync + a health readout.
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryModel

    @State private var health: MusicboxAPI.HealthResult?
    @State private var isCheckingHealth = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    // http://<lan-ip-or-tailscale>:<port> — no trailing /v1
                    TextField("Base URL (http://…)", text: $settings.baseURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    // NOTE: token stored in UserDefaults for now; move to Keychain later.
                    SecureField("Bearer token", text: $settings.bearerToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Library") {
                    LabeledContent("Tracks", value: "\(library.trackCount)")
                    LabeledContent("Revision", value: "\(library.rev)")
                    Button {
                        Task { await library.syncNow() }
                    } label: {
                        HStack {
                            Text("Sync now")
                            if library.isSyncing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(library.isSyncing || settings.config == nil)
                    if let message = library.lastMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Health") {
                    Button {
                        Task { await checkHealth() }
                    } label: {
                        HStack {
                            Text("Check /v1/health")
                            if isCheckingHealth {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isCheckingHealth || settings.config == nil)
                    if let health {
                        healthRow(health)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    @ViewBuilder
    private func healthRow(_ result: MusicboxAPI.HealthResult) -> some View {
        switch result {
        case .ok(let body):
            Label(body, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unreachable(let reason):
            Label(reason, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private func checkHealth() async {
        guard let config = settings.config else { return }
        isCheckingHealth = true
        defer { isCheckingHealth = false }
        health = await MusicboxAPI.health(config: config)
    }
}
