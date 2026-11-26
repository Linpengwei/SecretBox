import Foundation

// The rule set of the capture engine: which labels mark a value as a secret,
// and how labels map onto the keys the record model uses.
//
// The server keeps the same rules in Python (`is_secret_key` and `key_words`
// in server/app/redaction.py, the alias table in server/app/ai.py).
// testsets/capture_golden.json holds both sides to the same expectations.

nonisolated enum CaptureRules {
    // MARK: Secret-class labels

    private static let cjkMarkers = [
        "密码", "密碼", "口令", "密钥", "秘钥", "私钥", "金钥", "金鑰", "令牌", "凭据",
        "授权码", "激活码", "提取码", "兑换码", "卡密", "购买码", "验证码", "安全码",
        "序列号", "序列號",
    ]
    // Substrings that mark a word ("ScriptPassphrase", "aws_secret_access_key",
    // "apikey"). `apikey` is one word, so the "...key" rule never sees it.
    private static let markers = [
        "passw", "passcode", "passphrase", "pincode", "secret", "token",
        "credential", "license", "licence", "serial", "signature", "cookie",
        "private", "apikey", "bearer", "totp", "authorization",
    ]
    // Secret-class only as a whole word: "laptop" is not an OTP, "keynote" is
    // not a key, "author" is not an auth.
    private static let secretWords: Set<String> = [
        "pwd", "otp", "cvv", "cvc", "salt", "seed", "auth", "pass", "pin", "sk", "wifi",
    ]
    // "...key" is secret-class unless the name says it identifies a key rather
    // than carrying one (access keys are identifiers and stay visible).
    private static let keyIdentifiers: Set<String> = ["access", "id", "public", "pub", "name", "path", "type", "ring"]
    // "...code" likewise: a postal or country code is not a license code.
    private static let codeIdentifiers: Set<String> = [
        "postal", "country", "region", "area", "zip", "status", "error",
        "http", "state", "response", "currency", "locale", "sort", "color",
        "promo", "discount", "tax",
    ]
    // Labels that talk about a password without being one: a hint, a policy,
    // or a reminder. Paths and URLs are handled as values instead: their keys
    // stay secret-class so a real secret under the same label is still hidden.
    private static let neverSecret = [
        "密码提示", "密码策略", "密码规则", "密码要求", "提示", "password_hint", "passwordhint", "pwdpolicy",
        "提醒", "通知", "轮换", "策略", "规则", "说明", "要求", "有效期", "过期", "时间", "命令", "脚本",
        "policy", "hint", "reminder", "expiry", "expires", "expired", "updated", "changed_at", "rotation", "rotated",
        "helper",
    ]
    /// Markers that lose to an `id`: "private_key_id" names a key, it does not
    /// carry one.
    private static let strongMarkers: Set<String> = [
        "passw", "passcode", "passphrase", "pincode", "token", "credential", "cookie", "signature",
        "authorization", "bearer", "totp",
    ]

    /// True when a label marks its value as secret-class. A secret under a
    /// label nobody thought of is the failure this rule exists to prevent, so
    /// it is biased towards "yes": a false positive costs a concealed field, a
    /// false negative a leaked secret.
    static func isSecretKey(_ key: String) -> Bool {
        let lowered = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.isEmpty { return false }
        if neverSecret.contains(where: lowered.contains) { return false }
        if cjkMarkers.contains(where: lowered.contains) { return true }
        let words = words(of: key)
        if words.contains(where: { word in markers.contains(where: word.contains) }) {
            // "...id" names the thing ("private_key_id", "secret_id") unless
            // a marker names the value itself ("token_id" is a token).
            if lowered.hasSuffix("id"), words.isDisjoint(with: strongMarkers) { return false }
            return true
        }
        if !words.isDisjoint(with: secretWords) { return true }
        if words.contains("key"), words.isDisjoint(with: keyIdentifiers) { return true }
        return words.contains("code") && words.isDisjoint(with: codeIdentifiers)
    }

    /// The words of a label, read both ways: split at word boundaries only
    /// ("WiFi" -> "wifi") and additionally at camelCase boundaries
    /// ("AuthToken" -> "auth", "token"). Either reading may be the meaningful
    /// one, so the rules are tested against the union.
    static func words(of key: String) -> Set<String> {
        func isWord(_ character: Character) -> Bool {
            character.isASCII && (character.isLetter || character.isNumber)
        }

        var result = Set<String>()
        var current = ""
        var previous: Character?

        func flush() {
            if !current.isEmpty {
                result.insert(current.lowercased())
                current = ""
            }
        }

        for character in key {
            if !isWord(character) {
                flush()
                previous = character
                continue
            }
            // camelCase boundary: "AuthToken" reads as "auth" and "token".
            if let previous, isWord(previous), !previous.isUppercase, character.isUppercase {
                flush()
            }
            current.append(character)
            previous = character
        }
        flush()

        // The unsplit reading as well, so "WiFi" keeps its word.
        let whole = key.lowercased().filter(isWord)
        if !whole.isEmpty {
            result.insert(whole)
        }
        return result
    }

    // MARK: Canonical keys

    /// Free-form labels -> the keys the record model reads. Longest suffix
    /// wins, so "支付密码" and "登录密码" both resolve to "password".
    private static let aliases: [String: String] = [
        "密码": "password", "口令": "password", "密碼": "password",
        "授权码": "password", "激活码": "password", "提取码": "password",
        "兑换码": "password", "卡密": "password", "购买码": "password",
        "验证码": "password", "安全码": "password",
        "秘钥": "secret_key", "密钥": "secret_key", "访问密钥": "secret_key", "金钥": "secret_key", "金鑰": "secret_key",
        "私钥": "private_key", "令牌": "token", "凭据": "credential",
        "序列号": "serial", "序列號": "serial",
        "账号": "username", "账户": "username", "帐号": "username",
        "用户名": "username", "用户": "username", "工号": "username",
        "邮箱地址": "email", "邮箱": "email", "手机号": "phone", "手机": "phone",
        "网址": "url", "链接": "url", "地址": "url", "登录地址": "url", "访问地址": "url", "系统地址": "url", "页面地址": "url",
        "主机地址": "host", "主机名": "host", "主机": "host", "服务器": "host",
        "bootstrap地址": "brokers", "bootstrap": "brokers", "bootstrap_servers": "brokers",
        "端口": "port", "数据库": "database", "库名": "database",
        "服务": "service", "网站": "service", "系统": "service", "平台": "service",
        "环境": "env", "主题": "topic", "队列": "queue", "集群": "cluster", "项目": "project", "命名空间": "namespace",
        "名称": "name", "标题": "name", "备注": "notes", "说明": "notes",
        "区域": "region", "地区": "region", "存储桶": "bucket", "桶名": "bucket", "桶": "bucket",
        "类型": "type", "设备": "device", "公司": "org", "过期时间": "expiry", "有效期": "expiry",
    ]

    /// Lowercased, `-` and `.` folded to `_`, and a known free-form label
    /// replaced by the key it means. A copula glued to the label ("密码是")
    /// is dropped first: `密码是：x` is the label 密码 with a separator.
    static func canonicalKey(_ label: String) -> String {
        let normalized = label.trimmingCharacters(in: CharacterSet(charactersIn: "\"'` \t"))
            .replacingOccurrences(of: "(?:就是|是|为)+$", with: "", options: .regularExpression)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        if let exact = aliases[normalized] { return exact }
        let suffix = aliases.keys.filter { $0.count >= 2 && normalized.hasSuffix($0) }.max { $0.count < $1.count }
        return suffix.flatMap { aliases[$0] } ?? normalized
    }

    // MARK: Secret tiers

    /// Where a labeled secret sits in the order of "which one is THE secret
    /// of this paste". Lower wins; ties keep the order in the text.
    ///
    /// 0 — a login password ("密码", "password", "-p")
    /// 1 — a credential inside a URI, or a password flag on a command line
    /// 2 — any other secret label: an SK, a token, a license, a PIN
    /// 3 — no label at all (a bare password, the line after a keyword)
    /// 4 — a Chinese phrase read from the space after a label; kept only when
    ///     the paste holds no other secret
    static let passwordTier = 0
    static let credentialTier = 1
    static let otherSecretTier = 2
    static let unlabeledTier = 3
    static let phraseTier = 4

    private static let loginPasswordKeys: Set<String> = ["password", "passwd", "pwd", "pass", "passphrase", "passcode"]
    private static let paymentMarkers = ["支付", "交易", "取款", "转账", "查询密码", "购物"]

    static func tier(canonicalKey: String, rawKey: String) -> Int {
        let lowered = rawKey.lowercased()
        if loginPasswordKeys.contains(canonicalKey) {
            // A payment PIN is not the login password.
            return paymentMarkers.contains(where: lowered.contains) ? otherSecretTier : passwordTier
        }
        return otherSecretTier
    }

    // MARK: Text helpers

    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            (0x3400...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
        }
    }

    /// Sentence punctuation of either script, and the brackets that open a
    /// parenthetical remark.
    static let sentenceStops: Set<Character> = ["，", "。", "；", "！", "？", "、", ",", ";", ".", "!", "?"]
    static let openingBrackets: Set<Character> = ["（", "(", "【", "[", "「", "『", "<"]
    static let closingBrackets: Set<Character> = ["）", ")", "】", "]", "」", "』", ">"]

    /// Percent-decodes a value taken out of a URI. A string that is not
    /// valid percent-encoding is returned as it is.
    static func decoded(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    /// The spellings one secret can take inside a text: itself and its
    /// percent-encoded form.
    static func encodedForms(of secret: String) -> [String] {
        var forms = [secret]
        if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics), encoded != secret {
            forms.append(encoded)
        }
        return forms.filter { !$0.isEmpty }
    }

    /// A display label for a key: "access_key" -> "Access Key".
    static func displayLabel(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}
