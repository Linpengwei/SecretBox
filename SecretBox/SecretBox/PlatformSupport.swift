import CryptoKit
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
///
/// Secrets do not stay on the clipboard. A password that is copied and
/// forgotten would otherwise sit there until something else overwrites it —
/// readable by every app, recorded by clipboard managers, and (through
/// Universal Clipboard) handed to the user's other devices. So everything
/// written through `copySecret` is marked concealed and transient, and is
/// cleared after `secretClearDelay` — but only while it is still exactly what
/// was put there, so a later copy by the user is never clobbered.
enum PlatformClipboard {
    /// How long a copied password or verification code may stay.
    nonisolated static let secretClearDelay: Duration = .seconds(30)

    #if canImport(AppKit)
    // Pasteboard types from the nspasteboard.org convention: clipboard
    // managers skip concealed content and never keep transient content.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    #else
    private static let plainTextType = "public.utf8-plain-text"
    #endif

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

    /// Copies text that is not secret (an AI reference, a title). Nothing to clear.
    static func copy(_ text: String) {
        write(text, concealed: false)
    }

    /// Copies a password or verification code: concealed, transient, and
    /// removed from the clipboard on its own.
    static func copySecret(_ secret: String, clearAfter: Duration = secretClearDelay) {
        write(secret, concealed: true)

        // The comparison is done on a digest so this closure never holds the
        // plaintext for the whole delay.
        let fingerprint = Self.digest(secret)
        Task { @MainActor in
            try? await Task.sleep(for: clearAfter)
            guard !Task.isCancelled, let current = string, Self.digest(current) == fingerprint else { return }
            clear()
        }
    }

    static func clear() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        #elseif canImport(UIKit)
        UIPasteboard.general.items = []
        #endif
    }

    private static func write(_ text: String, concealed: Bool) {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if concealed {
            pasteboard.declareTypes([.string, concealedType, transientType], owner: nil)
        }
        pasteboard.setString(text, forType: .string)
        #elseif canImport(UIKit)
        if concealed {
            // The system drops the content itself at the expiration date, even
            // if the app is suspended in the meantime.
            UIPasteboard.general.setItems(
                [[plainTextType: text]],
                options: [.expirationDate: Date().addingTimeInterval(TimeInterval(secretClearDelay.totalSeconds))]
            )
        } else {
            UIPasteboard.general.string = text
        }
        #endif
    }

    private static func digest(_ text: String) -> SHA256.Digest {
        SHA256.hash(data: Data(text.utf8))
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
