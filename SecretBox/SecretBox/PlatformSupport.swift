import Foundation
import LocalAuthentication

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Drops whatever field/text view currently holds the keyboard. Programmatic
/// sheet dismissal on iOS can silently lose the race against an attached
/// keyboard, so the editor closes its inputs before flipping the presented
/// binding.
@MainActor
enum PlatformKeyboard {
    static func resignActiveResponder() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

/// Cross-platform clipboard access: AppKit on macOS, UIKit elsewhere.
enum PlatformClipboard {
    static var string: String? {
        get {
            #if canImport(AppKit)
            return NSPasteboard.general.string(forType: .string)
            #elseif canImport(UIKit)
            return UIPasteboard.general.string
            #else
            return nil
            #endif
        }
    }

    static func copy(_ text: String) {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

/// Gate for the per-record "re-prompt" permission (Bitwarden's master
/// password re-prompt equivalent): Touch ID / Face ID / device passcode
/// before a protected secret is revealed or copied. Injectable so tests can
/// simulate enrolled / not-enrolled / cancelled devices. LAContext is safe
/// off the main actor, so the gate stays nonisolated to allow use as a
/// default argument.
protocol ReauthGate: Sendable {
    /// Returns true when the user authenticated successfully. A device with
    /// no biometrics or passcode enrolled simply reports false — callers
    /// surface that as "unlock unavailable" instead of bypassing the gate.
    func authenticate(reason: String) async -> Bool
}

struct BiometricReauthGate: ReauthGate {
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

/// Test double: scripted outcomes with a tally of the challenges issued.
final class StubReauthGate: ReauthGate {
    private(set) var challengeCount = 0
    var nextResult: Bool

    init(nextResult: Bool) {
        self.nextResult = nextResult
    }

    func authenticate(reason: String) async -> Bool {
        challengeCount += 1
        return nextResult
    }
}
