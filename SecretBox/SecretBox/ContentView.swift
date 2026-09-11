import SwiftUI

struct ContentView: View {
    @ObservedObject var model: SecretBoxAppModel
    private let environment = ProcessInfo.processInfo.environment

    private var showsMenuBarTestPanel: Bool {
        environment["SECRETBOX_UI_TEST_MENU_BAR"] == "1"
    }

    var body: some View {
        Group {
            if model.isAuthenticated {
                Group {
                    if showsMenuBarTestPanel {
                        HStack(spacing: 0) {
                            RecordVaultView(model: model, compact: true)
                                .frame(width: 318)
                                .padding(16)

                            Divider()

                            SearchVaultView(model: model)
                        }
                    } else {
                        SearchVaultView(model: model)
                    }
                }
                    #if os(macOS)
                    .toolbar {
                        ToolbarItem(placement: .automatic) {
                            Button {
                                Task { await model.runSmartOrganizationNow() }
                            } label: {
                                Label("AI Organize", systemImage: "wand.and.stars")
                            }
                            .accessibilityIdentifier("toolbar.organize")
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                model.settingsPresented = true
                            } label: {
                                Label("Settings", systemImage: "slider.horizontal.3")
                            }
                        }
                    }
                    #endif
                    .sheet(isPresented: $model.settingsPresented) {
                        SettingsView(model: model)
                    }
                    .sheet(isPresented: $model.editorPresented) {
                        VaultItemEditorView(model: model)
                    }
            } else {
                LoginView(model: model)
            }
        }
        .task {
            await model.bootstrap()
        }
    }
}
