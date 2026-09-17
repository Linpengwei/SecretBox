#if canImport(AppKit)
import SwiftUI
import XCTest
@testable import SecretBox

/// Regenerates the documentation screenshots in `docs/screenshots/` from
/// deterministic demo data (InMemoryRecordStore + fake credentials only —
/// never the user's real vault). Renders offscreen via SnapshotLite so the
/// images are stable across machines.
@MainActor
final class DocsScreenshotsTests: XCTestCase {
    @MainActor
    private static var screenshotsDirectory: URL {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return testsDir
            .deletingLastPathComponent()      // SecretBox/
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("docs/screenshots")
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "DocsScreenshots.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeDemoModel(store: RecordStoring = InMemoryRecordStore()) async -> SecretBoxAppModel {
        let model = SecretBoxAppModel(
            environment: ["SECRETBOX_UI_TEST": "1", "SECRETBOX_UI_TEST_AUTH": "logged_in"],
            defaults: freshDefaults(),
            recordStore: store
        )
        await seedDemoVault(into: model)
        return model
    }

    /// Seeds the demo vault. UI-test mode wipes the store at init (hermetic
    /// runs), so records must be saved AFTER the model is constructed.
    private func seedDemoVault(into model: SecretBoxAppModel) async {
        model.pastedText = "redis://default:RedisProd%232026@redis-prod.internal:6379/0 env=prod service=order-cache"
        await model.saveFromPastedText()
        model.pastedText = "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod"
        await model.saveFromPastedText()
        model.pastedText = "access_key=AKIAIOSFODNN7EXAMPLE secret_key=wJalrXUtnFEMI7example env=prod bucket=release-artifacts endpoint=https://s3.internal"
        await model.saveFromPastedText()
        // A record with two-step verification attached (fake demo seed).
        model.pastedText = "service=Billing Console username=billing-ops password=BillingOps#2026 url=https://billing.internal otpauth://totp/Billing%20Console:billing-ops?secret=JBSWY3DPEHPK3PXP&issuer=Billing%20Console&period=30"
        await model.saveFromPastedText()
    }

    private func save<V: View>(_ view: V, size: CGSize, appearance: NSAppearance? = nil, named name: String) throws {
        let directory = Self.screenshotsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = SnapshotLite.render(view.frame(width: size.width, height: size.height), size: size, appearance: appearance)
        let data = try XCTUnwrap(SnapshotLite.pngData(image))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    func testGenerateDocumentationScreenshots() async throws {
        let light = NSAppearance(named: .vibrantLight)

        // 1. Login screen.
        let loggedOut = SecretBoxAppModel(
            environment: ["SECRETBOX_UI_TEST": "1", "SECRETBOX_UI_TEST_AUTH": "logged_out"],
            defaults: freshDefaults(),
            recordStore: InMemoryRecordStore()
        )
        try save(LoginView(model: loggedOut), size: CGSize(width: 960, height: 1080), appearance: light, named: "login")

        // 2. Main vault window: browser + detail with the live TOTP code.
        let model = await makeDemoModel()
        model.searchQuery = "billing"
        await model.searchPasswords()
        try save(SearchVaultView(model: model), size: CGSize(width: 2400, height: 1500), appearance: light, named: "vault-main")

        // 3. Quick capture sheet with detected preview.
        let captureModel = await makeDemoModel()
        captureModel.beginCreate()
        captureModel.pastedText = "redis://default:RedisProd%232026@redis-cache.internal:6379/0 env=prod service=session-cache"
        try save(VaultItemEditorView(model: captureModel), size: CGSize(width: 1640, height: 1240), appearance: light, named: "quick-capture")

        // 4. Editor: TOTP + permission matrix on an existing record.
        if let record = model.filteredResults.first(where: { $0.totp != nil }) ?? model.filteredResults.first {
            model.beginEditing(record)
        }
        try save(VaultItemEditorView(model: model), size: CGSize(width: 1640, height: 1560), appearance: light, named: "edit-totp-permissions")

        // 5. Settings sheet.
        let settingsModel = await makeDemoModel()
        settingsModel.serverEnabled = true
        try save(SettingsView(model: settingsModel), size: CGSize(width: 1160, height: 1080), appearance: light, named: "settings")

        // 6. macOS menu bar panel: capture (left) and quick access (right).
        //    Both models seed their vault after construction (UI-test init
        //    wipes the store), and the recent list is built by driving quick
        //    copies — the last one (the TOTP record) leaves its feedback
        //    capsule in place for the render.
        let menubarCaptureModel = SecretBoxAppModel(
            environment: ["SECRETBOX_UI_TEST": "1", "SECRETBOX_UI_TEST_AUTH": "logged_in"],
            defaults: freshDefaults(),
            recordStore: InMemoryRecordStore()
        )
        await seedDemoVault(into: menubarCaptureModel)
        menubarCaptureModel.pastedText = "kafka brokers=stream-a.internal:9092,stream-b.internal:9092 username=stream_ro password=StreamRO#2026 topic=stream.events env=prod"

        let menubarSearchModel = SecretBoxAppModel(
            environment: ["SECRETBOX_UI_TEST": "1", "SECRETBOX_UI_TEST_AUTH": "logged_in",
                          "SECRETBOX_UI_TEST_MENU_BAR_MODE": "search"],
            defaults: freshDefaults(),
            recordStore: InMemoryRecordStore()
        )
        await seedDemoVault(into: menubarSearchModel)
        for record in menubarSearchModel.localRecords.reversed() {
            await menubarSearchModel.quickAccessCopyPassword(for: record)
        }

        try save(
            HStack(spacing: 24) {
                RecordVaultView(model: menubarCaptureModel, compact: true)
                RecordVaultView(model: menubarSearchModel, compact: true)
            }
            .padding(28)
            .background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 740, height: 620),
            appearance: light,
            named: "menubar-panels"
        )
    }
}
#endif
