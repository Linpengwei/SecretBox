#if canImport(AppKit)
import SwiftUI
import XCTest
@testable import SecretBox

@MainActor
final class ViewSnapshotTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "ViewSnapshotTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testLoginViewSnapshot() {
        let model = SecretBoxAppModel(defaults: freshDefaults(), recordStore: InMemoryRecordStore())
        model.setAuthenticated(false)

        assertViewSnapshot(
            of: LoginView(model: model),
            size: CGSize(width: 460, height: 540),
            named: "login-light"
        )
        assertViewSnapshot(
            of: LoginView(model: model),
            size: CGSize(width: 460, height: 540),
            appearance: NSAppearance(named: .darkAqua),
            named: "login-dark"
        )
    }

    func testMenuBarCompactCardSnapshot() {
        let model = SecretBoxAppModel(
            environment: ["SECRETBOX_UI_TEST": "1", "SECRETBOX_UI_TEST_AUTH": "logged_in"],
            defaults: freshDefaults(),
            recordStore: InMemoryRecordStore()
        )

        assertViewSnapshot(
            of: RecordVaultView(model: model, compact: true),
            size: CGSize(width: 330, height: 520),
            named: "menu-bar-capture"
        )
    }

    func testSearchVaultWithSeededResultsSnapshot() async {
        let model = SecretBoxAppModel(
            environment: ["SECRETBOX_UI_TEST": "1", "SECRETBOX_UI_TEST_AUTH": "logged_in"],
            defaults: freshDefaults(),
            recordStore: InMemoryRecordStore()
        )
        model.searchQuery = "billing"
        await model.searchPasswords()

        assertViewSnapshot(
            of: SearchVaultView(model: model),
            size: CGSize(width: 1180, height: 780),
            named: "search-seeded"
        )
    }

    func testVaultEditorCaptureSheetSnapshot() {
        let model = SecretBoxAppModel(
            environment: ["SECRETBOX_UI_TEST": "1", "SECRETBOX_UI_TEST_AUTH": "logged_in"],
            defaults: freshDefaults(),
            recordStore: InMemoryRecordStore()
        )
        model.pastedText = "redis://default:RedisProd#2026@redis-prod.internal:6379/0 env=prod service=order-cache"

        assertViewSnapshot(
            of: VaultItemEditorView(model: model),
            size: CGSize(width: 820, height: 620),
            named: "editor-capture"
        )
    }

    /// Fixed reference date (RFC 6238 vector instant) keeps the digits and
    /// the countdown ring byte-stable across runs.
    private let snapshotInstant = Date(timeIntervalSince1970: 1_111_111_109)

    func testTOTPCodeViewSnapshot() {
        let secret = TOTPSecret(
            secret: "JBSWY3DPEHPK3PXP",
            issuer: "GitHub",
            account: "ops-bot@example.com"
        )
        assertViewSnapshot(
            of: TOTPCodeView(secret: secret, date: snapshotInstant, onCopy: { _ in }),
            size: CGSize(width: 420, height: 96),
            named: "totp-code"
        )
    }

    func testTOTPCodeViewMaskedSnapshot() {
        let secret = TOTPSecret(secret: "JBSWY3DPEHPK3PXP", issuer: "GitHub")
        assertViewSnapshot(
            of: TOTPCodeView(secret: secret, date: snapshotInstant, masked: true, onCopy: { _ in }),
            size: CGSize(width: 420, height: 96),
            named: "totp-code-masked"
        )
    }
}
#endif
