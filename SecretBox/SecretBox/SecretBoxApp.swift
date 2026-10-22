//
//  SecretBoxApp.swift
//  SecretBox
//
//  Created by liu hanze on 2026/4/4.
//

import AppKit
import SwiftUI
import os

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

    init() {
        Self.reapFrozenSiblingInstances()
    }

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

    // A SecretBox instance left traced or stopped by an abandoned Xcode debug
    // session is invisible but still registered with LaunchServices, so opening
    // the app merely "activates" the frozen process and nothing ever appears.
    // Reap such siblings so the launch proceeds; healthy instances are left
    // alone (the test host legitimately runs alongside the installed Release
    // app, and this instance itself must stay).
    private static func reapFrozenSiblingInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let siblings = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != getpid() }
        let logger = Logger(subsystem: bundleID, category: "launch")
        for app in siblings where isProcessFrozen(app.processIdentifier) {
            logger.warning("Terminating frozen sibling instance (pid \(app.processIdentifier, privacy: .public)) left by an abandoned debug session")
            kill(app.processIdentifier, SIGKILL)
        }
    }

    private static func isProcessFrozen(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
        // SSTOP: process stopped (e.g. SIGSTOP); P_TRACED: held by a debugger.
        return Int32(info.kp_proc.p_stat) == SSTOP || info.kp_proc.p_flag & P_TRACED != 0
    }
}
