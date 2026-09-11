//
//  SecretBoxApp.swift
//  SecretBox
//
//  Created by liu hanze on 2026/4/4.
//

import SwiftUI

@main
struct SecretBoxApp: App {
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    // The test host must never touch the real Keychain: unit tests inject their
    // own stores, but the host app instance would otherwise hit a keychain ACL
    // prompt at launch (the vault item belongs to the installed Release app)
    // and hang the runner.
    @StateObject private var model = SecretBoxAppModel(
        recordStore: isRunningTests ? InMemoryRecordStore() : KeychainRecordStore()
    )
    private let isUITestRun = Self.isRunningTests

    var body: some Scene {
        #if os(macOS)
        Window("SecretBox", id: "main") {
            ContentView(model: model)
        }

        MenuBarExtra("SecretBox", systemImage: "key.fill") {
            if isUITestRun {
                EmptyView()
            } else {
                RecordVaultView(model: model, compact: true)
            }
        }
        .menuBarExtraStyle(.window)
        #else
        WindowGroup {
            ContentView(model: model)
        }
        #endif
    }
}
