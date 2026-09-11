import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SecretBoxAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            settingsContent
        }
        .scrollDismissesKeyboard(.immediately)
        .background(AppTheme.pageBackground(colorScheme))
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Server and AI Provider")
                .font(.title2.weight(.semibold))

            GroupBox("Server") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable server features", isOn: $model.serverEnabled)
                    TextField("Server URL", text: $model.serverURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.serverEnabled)
                    Text(model.serverEnabled
                         ? "Point this to the FastAPI service, for example `http://127.0.0.1:8000`."
                         : "Server disabled. The app works in local-only MVP mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("OpenAI-compatible provider") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Base URL", text: $model.providerBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.serverEnabled)
                    SecureField("API Key", text: $model.providerAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.serverEnabled)
                    TextField("Model", text: $model.providerModel)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.serverEnabled)
                    Text(model.serverEnabled ? (model.providerConfigured ? "Configured on server" : "Not configured on server") : "Provider settings are available only when server mode is enabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Smart Organization") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("New captures use built-in templates first. Once unmatched custom items pass 20, SecretBox reclusters them and reruns classification. The same pass also runs during periodic review.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Periodic review")
                        Spacer()
                        Stepper(value: $model.organizationIntervalDays, in: 1...30, step: 1) {
                            Text("Every \(Int(model.organizationIntervalDays)) day(s)")
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 190, alignment: .trailing)
                    }

                    Text(model.organizationSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("AI Auto Organize Now") {
                        Task { await model.runSmartOrganizationNow() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings.organizeNow")
                }
            }

            HStack(spacing: 12) {
                Button("Save Settings") {
                    Task { await model.saveProviderSettings() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.serverEnabled)

                Button("Reload") {
                    Task { await model.loadProviderSettings() }
                }
                .buttonStyle(.bordered)
                .disabled(!model.serverEnabled)

                Spacer()

                Button("Close") {
                    dismiss()
                }
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 520)
        #else
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        #endif
    }
}
