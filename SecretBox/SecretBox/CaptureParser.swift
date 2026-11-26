import Foundation

/// One paste, read and classified: everything the app needs to store it.
nonisolated struct ParsedCapture: Hashable, Sendable {
    /// "redis", "database", "s3", "kafka", "aksk", "account" or "custom".
    let templateType: String
    let clusterDecision: ClusterDecision
    let signals: [VaultSignal]
    /// Every secret in the paste. The first one is the record's secret.
    let secrets: [CapturedSecret]
    /// Ordinary fields, then any secret beyond the first as a concealed field.
    let fields: [VaultField]
    let name: String
    let notes: String
    /// The paste with every secret taken out, for storage as context.
    let excerpt: String?

    var itemType: String { templateType == "account" ? "login" : "secret" }
    var primarySecret: String? { secrets.first?.value }
    var secondarySecrets: [CapturedSecret] { Array(secrets.dropFirst()) }
    var hasSecret: Bool { primarySecret != nil }
}

// The capture engine: raw paste text in, a structured record out.
//
// This is the app's one implementation of capture. It is a pure function of
// its input — no model state, and no collection iteration order deciding an
// outcome — and it is not isolated to any actor, so it can run wherever the
// caller is. The server keeps a frozen copy of the older rules in Python
// (server/app/ai.py); testsets/capture_golden.json measures both.
nonisolated enum CaptureParser {
    static func parse(_ raw: String, overrides: [String: String] = [:], typeOverride: String? = nil) -> ParsedCapture {
        parse(CaptureExtraction.read(raw), overrides: overrides, typeOverride: typeOverride)
    }

    /// - Parameters:
    ///   - overrides: corrections made in the preview, by field key. An empty
    ///     string removes the field. They reach every derived value — fields,
    ///     signals, the name — so the record stores what the user confirmed.
    ///   - typeOverride: a template chosen by hand in the preview.
    static func parse(_ extraction: CaptureReading, overrides: [String: String] = [:], typeOverride: String? = nil) -> ParsedCapture {
        let scrubbed = CaptureExtraction.scrub(extraction.text, secrets: extraction.secrets)
        // The paste as written follows the same corrections as the scrubbed
        // one; it is only ever read by the template rules, never stored.
        var rawText = extraction.text
        var keyValues = extraction.keyValues
        var labels = Set(extraction.pairs.map { CaptureRules.canonicalKey($0.rawKey) })
        var text = scrubbed

        for key in overrides.keys.sorted() {
            guard let value = overrides[key] else { continue }
            if value.isEmpty {
                keyValues.removeValue(forKey: key)
            } else if let original = keyValues[key] {
                text = text.replacingOccurrences(of: original, with: value)
                rawText = rawText.replacingOccurrences(of: original, with: value)
                keyValues[key] = value
            } else {
                text += " \(key)=\(value)"
                rawText += " \(key)=\(value)"
                keyValues[key] = value
                labels.insert(key)
            }
        }

        let primary = extraction.primarySecret
        let signals = CaptureClassification.signals(
            text: text,
            keyValues: keyValues,
            labels: labels,
            secret: primary,
            hasURICredential: extraction.uris.contains { $0.password != nil }
        )
        let cluster = CaptureClassification.decideCluster(for: signals, text: text, keyValues: keyValues)
        let secretScheme = extraction.secrets.first.flatMap { $0.source == .uri ? $0.rawKey.replacingOccurrences(of: "://", with: "") : nil }
        let templateType = typeOverride ?? CaptureClassification.templateType(
            for: cluster, text: rawText, keyValues: keyValues, labels: labels, secretScheme: secretScheme
        )

        var fields = CaptureClassification.fields(templateType: templateType, text: text, keyValues: keyValues)
        fields = CaptureClassification.complete(fields, pairs: pairsForFields(extraction), secondarySecrets: extraction.secondarySecrets)
        for key in overrides.keys.sorted() {
            guard let value = overrides[key] else { continue }
            if value.isEmpty {
                fields.removeAll { $0.key == key }
                continue
            }
            // An override changes the value, never the protection class. A
            // corrected secondary secret must not reappear as an ordinary field.
            let concealed = fields.contains { $0.key == key && $0.hidden } || CaptureRules.isSecretKey(key)
            if let index = fields.firstIndex(where: { $0.key == key }) {
                fields[index].value = value
                fields[index].hidden = fields[index].hidden || concealed
            } else {
                fields.append(CaptureClassification.field(key, CaptureRules.displayLabel(key), value, semantic: key, section: "Details", order: 500, hidden: concealed))
            }
        }
        fields = CaptureClassification.deduplicated(fields)
        if let excerpt = orNil(scrubbed) {
            fields.append(CaptureClassification.field("source_excerpt", "Source Excerpt", String(excerpt.prefix(240)), semantic: "source_excerpt", section: "Metadata", order: 999))
        }

        let heading = heading(in: extraction)
        let site = heading == nil ? siteLabel(in: scrubbed, keyValues: keyValues) : nil
        let label = orNil(keyValues["name"]) ?? orNil(keyValues["title"]) ?? heading ?? site
        let name = label ?? CaptureClassification.recordName(templateType: templateType, keyValues: keyValues, fields: fields)
        let notes = heading ?? CaptureClassification.notes(templateType: templateType, keyValues: keyValues, fallback: orNil(scrubbed))

        return ParsedCapture(
            templateType: templateType,
            clusterDecision: cluster,
            signals: signals,
            secrets: extraction.secrets,
            fields: fields,
            name: name,
            notes: notes,
            excerpt: orNil(scrubbed)
        )
    }

    private static func orNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// The labeled values that may become free-form fields: those a URI
    /// parameter supplied are already represented by the URI's own fields.
    private static func pairsForFields(_ extraction: CaptureReading) -> [CapturePair] {
        extraction.pairs.filter { $0.source == .keyValue || $0.source == .naturalLanguage || $0.source == .commandFlag }
    }

    // MARK: What the user called it

    /// The first line of a notification-style paste, when the lines below it
    /// carry the details ("行政后勤OA 账号开通通知"). Nil for a single-line paste
    /// or when the first line is itself a value or a command.
    static func heading(in extraction: CaptureReading) -> String? {
        guard extraction.lines.count >= 2, let first = extraction.lines.first else { return nil }
        let rest = extraction.lines.dropFirst()
        guard rest.contains(where: { CaptureExtraction.isDetailLine($0) }),
              !CaptureExtraction.isDetailLine(first),
              !first.contains("://"), first.count <= 40 else { return nil }
        let value = CaptureExtraction.scrub(first, secrets: extraction.secrets)
            .trimmingCharacters(in: CharacterSet(charactersIn: "：:，,。"))
        let trimmed = value.replacingOccurrences(of: #"(账号|帐户|账户|密码|口令)?(开通|下发|变更|重置)?(通知|信息|详情|邮件)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        return trimmed
    }

    /// The site a hand-written sentence in Chinese is about: what comes
    /// before the first credential word ("你在居家好物网的登录密码就是…").
    static func siteLabel(in text: String, keyValues: [String: String]) -> String? {
        guard keyValues["url"] == nil, keyValues["service"] == nil, keyValues["label"] == nil,
              let cut = text.range(of: #"账号|帐号|账户|用户名|密码|口令|密钥|邮箱|验证码|授权码"#, options: .regularExpression),
              cut.lowerBound > text.startIndex else { return nil }
        let prefix = text[..<cut.lowerBound]
        let cleaned = prefix
            .replacingOccurrences(of: #"^(?:我|你|他|她|它)(?:在|的|是)+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "的在是，,。：:"))
        guard (2...20).contains(cleaned.count), cleaned.contains(where: CaptureRules.isCJK),
              !["请", "麻烦", "帮我", "记", "这个", "一下", "这里", "那个", "存", "保存"].contains(where: cleaned.contains) else { return nil }
        return cleaned
    }

    // MARK: Smart Preview

    /// The chips shown above the preview's editable fields.
    static func previewTags(signals: [VaultSignal], fields: [VaultField], secret: String?, templateType: String) -> [String] {
        var tags: [String] = []
        for signal in prioritizedPreviewSignals(signals) {
            if let rendered = previewTag(key: signal.name, value: signal.value), !rendered.isEmpty {
                tags.append(rendered)
            }
        }

        let prioritizedKeys = [
            "url", "endpoint", "host", "brokers",
            "service", "label", "account",
            "database", "bucket", "topic", "scope", "project", "vhost",
            "env", "region", "provider", "engine", "mechanism",
            "username", "access_key",
        ]
        for key in prioritizedKeys {
            if let value = fields.first(where: { $0.key == key })?.value,
               let rendered = previewTag(key: key, value: value),
               !rendered.isEmpty {
                tags.append(rendered)
            }
        }

        let renderedSecret = secret.flatMap(secretTag)
        if let renderedSecret {
            tags.append(renderedSecret)
        }
        if tags.isEmpty {
            tags.append("source:\(templateType)")
        }

        var unique: [String] = []
        for tag in tags where !unique.contains(tag) {
            unique.append(tag)
        }
        if let renderedSecret, let secretIndex = unique.firstIndex(of: renderedSecret), secretIndex >= 7 {
            unique.remove(at: secretIndex)
            if unique.count >= 7 {
                unique[6] = renderedSecret
            } else {
                unique.append(renderedSecret)
            }
        }
        return Array(unique.prefix(7))
    }

    private static let previewSignalPriority: [String: Int] = [
        "url": 120, "endpoint": 120, "host": 115, "brokers": 110,
        "label": 105, "service": 105, "account": 95,
        "database": 90, "bucket": 90, "topic": 90, "scope": 85, "project": 85, "vhost": 85,
        "env": 80, "region": 75, "provider": 75, "engine": 70, "mechanism": 65,
        "username": 60, "access_key": 55,
    ]

    static func prioritizedPreviewSignals(_ signals: [VaultSignal]) -> [VaultSignal] {
        signals
            .filter { $0.category != .secret }
            .sorted { lhs, rhs in
                let left = previewSignalPriority[lhs.name, default: 0]
                let right = previewSignalPriority[rhs.name, default: 0]
                if left != right { return left > right }
                return lhs.name < rhs.name
            }
    }

    static func previewTag(key: String, value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch key {
        case "url", "endpoint":
            if let host = URL(string: trimmed)?.host, !host.isEmpty {
                return "\(key):\(host)"
            }
            if let host = CaptureClassification.host(from: trimmed), !host.isEmpty {
                return "\(key):\(host)"
            }
            return "\(key):\(trimmed)"
        case "host":
            return "host:\(trimmed)"
        case "brokers":
            return "brokers:\(trimmed)"
        case "label":
            return "label:\(trimmed)"
        case "service":
            return "label:\(trimmed)"
        case "account":
            return "account:\(trimmed)"
        case "database":
            return "db:\(trimmed)"
        case "bucket":
            return "bucket:\(trimmed)"
        case "topic":
            return "topic:\(trimmed)"
        case "mechanism":
            return "auth:\(trimmed)"
        case "username":
            return "user:\(trimmed)"
        case "access_key":
            return "ak:\(trimmed)"
        default:
            return "\(key):\(trimmed)"
        }
    }

    /// The last of a secret is shown in the preview so the user can tell the
    /// right value was picked — never the whole thing.
    static func secretTag(_ secret: String) -> String? {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "secret:••••\(trimmed.suffix(min(4, trimmed.count)))"
    }

    // MARK: Regular-expression helpers

    static func firstCapture(in text: String, pattern: String) -> String? {
        groups(in: text, pattern: pattern)?.first ?? nil
    }

    /// Capture groups of the first match; nil when there is none.
    static func groups(in text: String, pattern: String) -> [String?]? {
        CaptureParser.groups(in: text, pattern: pattern, caseInsensitive: true)
    }

    static func groups(in text: String, pattern: String, caseInsensitive: Bool) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1 ..< match.numberOfRanges).map { index in CapturePattern.group(text, match, index) }
    }

    static func groups(in text: String, _ match: NSTextCheckingResult) -> [String?]? {
        (1 ..< match.numberOfRanges).map { CapturePattern.group(text, match, $0) }
    }
}
