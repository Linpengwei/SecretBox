import Foundation
import CryptoKit

/// RFC 6238 TOTP generation, RFC 4648 base32 decoding, and Key-URI
/// (`otpauth://totp/...`) parsing — the client-side half of the Bitwarden
/// Integrated Authenticator equivalent. Codes are computed locally from the
/// stored seed and the current time; the server never generates or verifies
/// them. Time comes from an injectable provider so tests and snapshot
/// baselines stay deterministic.
enum TOTPEngine {
    /// RFC 4648 base32 (A–Z, 2–7). Tolerates lowercase, embedded whitespace,
    /// and missing `=` padding; any other character fails the decode so
    /// malformed seeds never reach storage.
    static func base32Decode(_ input: String) -> Data? {
        let alphabet: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var lookup: [Character: UInt8] = [:]
        for (index, character) in alphabet.enumerated() {
            lookup[character] = UInt8(index)
        }

        var accumulator = 0
        var bitCount = 0
        var data = Data()
        data.reserveCapacity(input.count * 5 / 8)

        for character in input {
            if character == "=" || character.isWhitespace { continue }
            guard let value = lookup[Character(character.uppercased())] else { return nil }
            accumulator = (accumulator << 5) | Int(value)
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                data.append(UInt8((accumulator >> bitCount) & 0xFF))
            }
        }
        return data.isEmpty ? nil : data
    }

    /// RFC 4226 dynamic truncation over the HMAC digest of the time-step
    /// counter. Returns a zero-padded code of `secret.digits` digits.
    static func code(for secret: TOTPSecret, at date: Date) -> String? {
        let period = max(1, secret.period)
        guard let keyData = base32Decode(secret.secret) else { return nil }
        let counter = UInt64(date.timeIntervalSince1970 / Double(period)).bigEndian
        let message = withUnsafeBytes(of: counter) { Data($0) }
        let key = SymmetricKey(data: keyData)

        let digest: Data
        switch secret.algorithm {
        case .sha1:
            digest = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256:
            digest = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512:
            digest = Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }

        let offset = Int(digest[digest.count - 1] & 0x0F)
        var binary = 0
        for byteIndex in 0..<4 {
            binary = (binary << 8) | Int(digest[digest.startIndex + offset + byteIndex])
        }
        binary &= 0x7FFF_FFFF

        var modulus = 1
        for _ in 0..<max(1, secret.digits) { modulus *= 10 }
        return String(format: "%0\(max(1, secret.digits))d", binary % modulus)
    }

    /// Seconds until the current code rotates (1…period, never 0 so the UI
    /// ring always shows a sliver of remaining time).
    static func secondsRemaining(period: Int, at date: Date) -> Int {
        let clamped = max(1, period)
        let elapsed = Int(date.timeIntervalSince1970)
        return clamped - (elapsed % clamped)
    }
}

extension TOTPSecret {
    /// Accepts either a full `otpauth://totp/...` Key URI or a bare base32
    /// seed (whitespace stripped, uppercased). Returns nil when nothing
    /// usable can be extracted — callers treat that as invalid input, not as
    /// "absent".
    static func fromUserInput(_ input: String) -> TOTPSecret? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("otpauth://") {
            return TOTPEngine.parseOTPAuthURI(trimmed)
        }
        let normalized = String(trimmed.filter { !$0.isWhitespace }).uppercased()
        guard TOTPEngine.base32Decode(normalized) != nil else { return nil }
        return TOTPSecret(secret: normalized)
    }
}

extension TOTPEngine {
    /// Parses the Google Key URI format:
    /// `otpauth://totp/Issuer:account?secret=...&issuer=...&digits=6&period=30&algorithm=SHA1`
    /// Counter-based `otpauth://hotp` URIs are rejected (out of scope).
    static func parseOTPAuthURI(_ raw: String) -> TOTPSecret? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Key URIs in the wild often contain unencoded spaces or non-ASCII
        // label text; percent-encode spaces so URL(string:) accepts them.
        let sanitized = trimmed.replacingOccurrences(of: " ", with: "%20")
        guard let url = URL(string: sanitized),
              url.scheme?.lowercased() == "otpauth",
              url.host?.lowercased() == "totp" else { return nil }

        var labelIssuer: String?
        var labelAccount: String?
        let label = url.path.isEmpty ? "" : String(url.path.dropFirst())
        if let decoded = label.removingPercentEncoding, !decoded.isEmpty {
            if let colon = decoded.firstIndex(of: ":") {
                labelIssuer = String(decoded[decoded.startIndex..<colon]).nilIfEmpty
                labelAccount = String(decoded[decoded.index(after: colon)...]).nilIfEmpty
            } else {
                labelAccount = decoded.nilIfEmpty
            }
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var secret: String?
        var digits = 6
        var period = 30
        var algorithm = TOTPAlgorithm.sha1
        var paramIssuer: String?
        for item in components?.queryItems ?? [] {
            let value = item.value?.removingPercentEncoding
            switch item.name.lowercased() {
            case "secret":
                secret = value
            case "digits":
                if let parsed = value.flatMap(Int.init) { digits = parsed }
            case "period":
                if let parsed = value.flatMap(Int.init) { period = parsed }
            case "algorithm":
                if let parsed = value.flatMap({ TOTPAlgorithm(rawValue: $0.uppercased()) }) { algorithm = parsed }
            case "issuer":
                paramIssuer = value
            default:
                break
            }
        }

        guard let secret, !secret.isEmpty,
              TOTPEngine.base32Decode(secret) != nil,
              (6...8).contains(digits),
              (15...120).contains(period) else { return nil }
        return TOTPSecret(
            secret: secret,
            issuer: paramIssuer ?? labelIssuer,
            account: labelAccount,
            digits: digits,
            period: period,
            algorithm: algorithm
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
