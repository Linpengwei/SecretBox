import Foundation

// Text -> labeled values and secrets: the reading half of the capture engine.
// `CaptureClassification` turns what is read here into a record.
//
// Everything here is a pure function of its input. Order comes from positions
// in the text, never from collection iteration order, so the same paste reads
// the same way on every launch.

/// A compiled regular expression. The patterns in the capture engine are
/// literals that the golden corpus exercises, so a pattern that fails to
/// compile is a programming error and is trapped here at first use.
nonisolated struct CapturePattern: @unchecked Sendable {
    private let regex: NSRegularExpression

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    func first(in text: String, from location: Int = 0) -> NSTextCheckingResult? {
        let length = (text as NSString).length - location
        guard length > 0 else { return nil }
        return regex.firstMatch(in: text, options: [], range: NSRange(location: location, length: length))
    }

    func all(in text: String) -> [NSTextCheckingResult] {
        let length = (text as NSString).length
        guard length > 0 else { return [] }
        return regex.matches(in: text, options: [], range: NSRange(location: 0, length: length))
    }

    static func group(_ text: String, _ match: NSTextCheckingResult, _ index: Int) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return (text as NSString).substring(with: range)
    }
}

/// One labeled value read from a paste.
nonisolated struct CapturePair: Hashable, Sendable {
    nonisolated enum Source: Hashable, Sendable {
        case keyValue
        case naturalLanguage
        case uri
        case uriParameter
        case commandFlag
    }

    /// Canonical key ("password", "host", "secret_key").
    let key: String
    /// The label as it was written.
    let rawKey: String
    /// What the label is worth. May be replaced by a scrubbed form when the
    /// value quotes a URI.
    var value: String
    let source: Source
    /// Position in the paste: line, then column. Keeps "first wins" stable.
    let order: Int
    /// False once a candidate was set aside (see `CaptureRules.phraseTier`).
    var isSecret: Bool
}

/// A secret read from a paste. `tier` orders secrets when a paste has more
/// than one (see `CaptureRules.tier(canonicalKey:rawKey:)`).
nonisolated struct CapturedSecret: Hashable, Sendable, Identifiable {
    var id: String { "\(order):\(key)" }
    let key: String
    let rawKey: String
    let value: String
    let source: CapturePair.Source
    let tier: Int
    let order: Int
}

nonisolated struct CaptureURIParameter: Hashable, Sendable {
    let key: String
    let rawKey: String
    let value: String
    let isSecret: Bool
}

/// A URI found in a paste, taken apart.
nonisolated struct CaptureURI: Hashable, Sendable {
    let scheme: String
    /// The URI as it can be stored: no userinfo, secret-class query
    /// parameters blanked.
    let clean: String
    /// Where the URI is, in the line it was found in.
    let range: NSRange
    let username: String?
    let password: String?
    let host: String?
    let port: String?
    /// First path segment: the database, the Redis db, the AMQP vhost.
    let resource: String?
    let parameters: [CaptureURIParameter]
}

/// Everything the capture engine read from one paste.
nonisolated struct CaptureReading: Sendable {
    /// As pasted, trimmed.
    let raw: String
    let lines: [String]
    /// Whitespace-normalized to one line. The classification rules that
    /// predate the engine read this form.
    let text: String
    /// Every labeled value, secrets included, in text order.
    let pairs: [CapturePair]
    /// Every secret, ordered by tier, then by position in the text.
    let secrets: [CapturedSecret]
    let uris: [CaptureURI]

    var primarySecret: String? { secrets.first?.value }
    var secondarySecrets: [CapturedSecret] { Array(secrets.dropFirst()) }

    /// Canonical key -> the first value under it. For the record-field lookups.
    var keyValues: [String: String] {
        var map: [String: String] = [:]
        for pair in pairs where !pair.isSecret && map[pair.key] == nil {
            map[pair.key] = pair.value
        }
        return map
    }
}

nonisolated enum CaptureExtraction {
    // MARK: Patterns

    // A URI runs to the next whitespace; `trimURI` then takes trailing prose
    // off its end, so a password with Chinese in it ("…：SalesBI2026，北斗！@h")
    // is kept whole while "…/0，请及时修改" is cut after the URI.
    private static let uriPattern = CapturePattern(#"\b[a-z][a-z0-9+.\-]*://[^\s]+"#, .caseInsensitive)
    // A command substitution is not paste content to read as credentials:
    // `export TOKEN=$(vault read -field=token secret/app)`.
    private static let commandSubstitutionPattern = CapturePattern(#"\$\([^)\n]*\)"#)
    private static let schemePrefixPattern = CapturePattern(#"^[A-Za-z][A-Za-z0-9+.\-]*://"#)
    // key, separator (half- or full-width), value (quoted, or up to whitespace).
    // A quoted key is JSON (`"password": "x"`); the quotes are cut off after.
    // Chinese quotes (“密码”) count as quotes too.
    // A key may hold one space, but only before a Chinese character
    // ("Bootstrap 地址", "测试环境 密码"). Otherwise the key before a URI would
    // swallow the pair that follows it ("endpoint=https://minio.internal
    // bucket=build-cache"), and `export AWS_ACCESS_KEY_ID` would not split.
    private static let pairPattern = CapturePattern(#"(["“”][^"“”\n]+["“”]|'[^'\n]+'|[‘’][^‘’\n]+[‘’]|[\p{Han}A-Za-z_][\p{Han}A-Za-z0-9_\-.](?:(?:[ \t](?=\p{Han}))?[\p{Han}A-Za-z0-9_\-.])*)\s*[:：=＝]\s*("[^"]*"|“[^”]*”|'[^']*'|‘[^’]*’|[^\s]+)"#)
    // `host:port` before a bare colon: not a label either.
    private static let hostPortPattern = CapturePattern(#"^(?=[A-Za-z0-9.\-]*[.\d])[A-Za-z0-9.\-]+:\d{1,5}$"#)
    // A `.pgpass` line: host, port, database, user, password.
    private static let pgpassPattern = CapturePattern(#"^(?=[A-Za-z0-9.\-]*(?:\.|localhost))([A-Za-z0-9.\-]+):(\d{0,5}):([^:\s]*):([^:\s]*):([^\s]+)$"#)
    // A value that stands for "the secret goes here" (`${DB_PASSWORD}`,
    // `{{ password }}`, `<password>`): a reference, not a secret.
    private static let referencePattern = CapturePattern(
        #"^(?:\$\{[^}]+\}|\$\([^\s]*|\$[A-Za-z_][A-Za-z0-9_]*|\{\{[^}]+\}\}|<[^<>]+>|%[A-Za-z_]+%)$"#
    )
    // Google's app passwords: four groups of four, written with spaces.
    private static let appPasswordTailPattern = CapturePattern(#"^(?: [A-Za-z0-9]{4}){3}(?![A-Za-z0-9])"#)
    // Where one value ends because the next pair starts ("Server=h;Port=5432",
    // "…：photo-archive老照片备份的访问秘钥：…"). An ASCII colon counts as a
    // separator only when a space follows it, so
    // "kafka-1.internal:9092,broker:9092" stays one brokers list.
    private static let nextPairPattern = CapturePattern(
        #"(?:[;；，,][ \t]*[\p{L}\p{N}_\- ]{1,32}?(?::[ \t]|[：=＝]))|(?:\p{Han}{1,12}(?:密码|口令|密碼|密钥|秘钥|私钥|令牌|序列号|账号|帐号|账户|用户名|用户|邮箱|手机号|网址|链接|地址|主机|端口|数据库|服务|环境|名称|备注|说明|类型|验证码|授权码|激活码|提取码|兑换码|卡密|购买码)\s*[：=＝])"#
    )
    private static let addressKeyPattern = CapturePattern(#"\d[.\-]\d"#)
    private static let cliUserPattern = CapturePattern(#"(?:(?<=\s)|^)(?:-u|--username|--user)[ \t]+([^\s]+)"#)
    private static let cliSecretPattern = CapturePattern(
        #"(?:(?<=\s)|^)(?:--password|--passwd|--pwd|--pass|--passphrase|--token|--secret|--api-key|--api_key|--key)(?:[ \t]+|=)([^\s]+)"#
    )
    // `-p` is a port for some tools; a purely numeric value is left alone.
    // Glued to its value it is a password only when the value is quoted
    // (`mysql -p'secret'`): `-port` and `-path` are other flags.
    private static let cliShortPasswordPattern = CapturePattern(#"(?:(?<=\s)|^)-p[ \t]+(?!\d+(?:\s|$))([^\s]+)"#)
    private static let cliGluedPasswordPattern = CapturePattern(#"(?:(?<=\s)|^)-p(?=[\"'`][^\"'`]*[\"'`](?:\s|$))([^\s]+)"#)
    // `Authorization: Bearer <token>`: the value is what follows the scheme.
    private static let authSchemeTailPattern = CapturePattern(#"^[ \t]+([^\s,;，；]+)"#)
    private static let authSchemeWords: Set<String> = ["bearer", "basic", "token", "digest"]
    // Another pair glued inside a value (`Environment=POSTGRES_PASSWORD=…`).
    private static let leadingPairPattern = CapturePattern(#"^[“"]?[A-Za-z_][A-Za-z0-9_\-.]*[”"]?[ \t]*[:：=]"#)

    private static let valueClass = #"[^\s，。；;，！？"'（）「」『』【】]+"#
    // "密码是 x", "密码她是 x", "密码更新了新的是 x", "购买码你们看好是这个 → x":
    // a secret label, up to sixteen characters of whatever the sentence puts
    // between the label and the copula, then the value.
    private static let copulaLeadOut = #"\s*(?:这个)?\s*(?:[→:>～—\-]+\s*)?"#
    private static let filler = #"[^：:=＝\n]{0,16}?(?:是|为)"#
    /// (pattern with the label as group 1 and the value as group 2)
    private static let nlCopulaPatterns: [CapturePattern] = [
        CapturePattern(#"(secret[\s\-]?key|secretkey|\bsk\b|私钥|金钥|金鑰|密钥|秘钥|序列号|serial(?: number)?|licen[cs]e)\#(filler)\#(copulaLeadOut)[「『"']?(\#(valueClass))"#, .caseInsensitive),
        CapturePattern(#"(passw(?:ord)?|passwd|pwd|密码|口令|密碼)\#(filler)\#(copulaLeadOut)[「『"']?(\#(valueClass))"#, .caseInsensitive),
        CapturePattern(#"(token|令牌|凭据|apikey|api[\s\-]?key)\#(filler)\s*[「『"']?(\#(valueClass))"#, .caseInsensitive),
        CapturePattern(#"(购买码|授权码|激活码|提取码|兑换码|卡密|验证码|安全码)\#(filler)\#(copulaLeadOut)[「『"']?(\#(valueClass))"#),
    ]
    // "Access Key 是 FAM-2024-7K9Q": an access key names an account, it is not
    // the secret — the secret key next to it is.
    private static let nlAccessKeyPattern = CapturePattern(#"(access[\s\-]?key|accesskey|\bak\b)\#(filler)\s*[「『"']?(\#(valueClass))"#, .caseInsensitive)
    // "初始密码 Xf4@Pk8#Rs2", and "密码 幸福快乐每一天". The value is a password
    // when it has Latin letters or digits, or when it is a short Chinese
    // phrase that does not read as a sentence about the password.
    private static let nlSpacePattern = CapturePattern(
        #"((?:支付|交易|取款|转账|查询|购物|登录|登陆|初始)?(?:passw(?:ord)?|passwd|pwd|passphrase|密码|口令|密碼|购买码|授权码|激活码|提取码|兑换码|卡密|密钥|秘钥|令牌|序列号|secret|token|licen[cs]e|serial(?: number)?))\s+(?:她|他|它)?(?:是|为)?\s*[「『"']?(\#(valueClass))"#,
        .caseInsensitive
    )
    // "购物密码20010515": the word before 密码 says which kind of password.
    private static let nlGluedPattern = CapturePattern(#"((?:支付|交易|取款|转账|查询|购物|登录|登陆|初始)?(?:密码|口令|密碼|购买码|授权码|激活码|提取码|兑换码|卡密|密钥|秘钥|令牌|序列号))([A-Za-z0-9][A-Za-z0-9@#$%^&*!?+_\-=.]{3,})"#)
    private static let nlUserIsPattern = CapturePattern(#"(账号|帐号|账户|用户名|用户|邮箱|工号|手机号|手机)\s*(?:就(?:是|为)?|是|为)\s*[「『"']?(\#(valueClass))"#)
    // A line that ends on a secret label ("这是公司redis的密码", "密码给你 收好
    // 别弄丢"): the secret itself follows on the next line. The label must not
    // be followed by a value glued to it or by a copula — those are read elsewhere.
    private static let keywordTailPattern = CapturePattern(
        #"(密码|口令|密碼|密钥|秘钥|令牌|序列号|验证码|授权码|激活码|提取码|兑换码|卡密|购买码|password|passwd|pwd|secret|token|licen[cs]e|serial)(?![A-Za-z0-9])(?!\s*(?:她|他|它|这个)?(?:是|为))[^：:=＝]*$"#,
        .caseInsensitive
    )

    /// Words with which a sentence goes on after a password written in
    /// Chinese ("家和万事兴123你到时候直接输…").
    private static let proseOnsets = [
        "你", "我", "他", "她", "它", "这", "那", "就", "若", "请", "别",
        "记得", "千万", "务必", "然后", "之后", "以后", "如果", "如需", "给", "自己", "你们", "大家",
        "登录后", "登陆后", "使用前", "下次", "不要",
    ]
    /// What a labeled value says when the paste talks about the secret instead
    /// of giving it ("密码 另行发送", "password: same as above").
    private static let notValues: Set<String> = [
        "是", "为", "就是", ":", "：", "=", "如下", "同上", "见上", "无", "没有", "暂无", "略",
        "另行发送", "另行通知", "稍后发", "稍后给", "私下发", "给你", "给你了", "发你", "发你了", "收好",
        "记好", "记一下", "记住了", "保存好", "备份好", "别弄丢", "别外传", "尽快改", "及时修改",
        "空", "空的", "为空", "不填", "无需", "待定", "稍后", "未知", "待通知", "同前", "不变", "见邮件", "见附件", "问管理员",
        "is", "required", "to", "not", "the", "a", "and", "or", "your", "my", "reset", "expired", "changed", "incorrect", "wrong", "forgot", "forgotten",
        "n/a", "na", "tbd", "todo", "none", "null", "same", "same as above", "see above", "ask it", "ask admin",
        "see", "ask", "refer", "check", "true", "false", "yes", "no", "on", "off",
    ]
    /// What a Chinese remark under a secret label is made of. A Chinese value
    /// after a secret label in a sentence is read as a password only when none
    /// is in it.
    private static let hanProseMarkers = [
        "请", "别", "记得", "务必", "需要", "必须", "不要", "另行", "见上", "同上", "妥善", "保管",
        "修改", "更新", "重置", "过期", "有效", "位以", "字符", "大小写", "字母", "至少", "没有", "暂无",
        "忘记", "忘了", "发给", "给你", "发你", "告知", "输入", "一下", "登录后", "使用时",
        "已发送", "发送", "短信", "联系", "管理员", "邮箱", "手机", "锁定", "解锁", "次数",
        "为空", "空时", "默认", "轮换", "更换",
    ]
    /// The same, for a value that stands behind a separator ("口令：见群公告").
    /// Only phrases of two characters or more: a password may well hold a 请
    /// or a 别 ("别忘了我").
    private static let hanStandIns = [
        "请勿", "请见", "详见", "见群", "见上", "同上", "见邮件", "见附件", "另行", "待定", "稍后", "未知",
        "群公告", "公告", "统一更换", "轮换", "更换", "联系", "管理员", "已发送", "发送到", "为空", "暂无",
        "没有", "不填", "无需", "待通知", "当面", "线下", "单独发", "私下", "口头",
    ]
    private static let placeholders: Set<String> = [
        "[redacted]", "******", "••••", "xxxx", "xxx", "<password>", "{{password}}", "changeme", "your_password", "your-password", "********",
    ]
    private static let cjkStops: Set<Character> = ["，", "。", "；", "！", "？", "、"]

    // MARK: Reading a paste

    static func read(_ raw: String) -> CaptureReading {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var pairs: [CapturePair] = []
        var secrets: [CapturedSecret] = []
        var uris: [CaptureURI] = []

        for (lineIndex, line) in lines.enumerated() {
            let base = lineIndex * 100_000
            if readPgpass(in: line, base: base, pairs: &pairs, secrets: &secrets) { continue }
            // URIs are read first: nothing else may read inside them, or
            // `default:pw@host` becomes an ordinary key/value pair.
            var ranges = readURIs(in: line, base: base, pairs: &pairs, secrets: &secrets, uris: &uris)
            ranges.append(contentsOf: commandSubstitutionPattern.all(in: line).map(\.range))
            readPairs(in: line, base: base, outside: ranges, pairs: &pairs, secrets: &secrets)
            readCommandFlags(in: line, base: base, outside: ranges, pairs: &pairs, secrets: &secrets)
            readNaturalLanguage(in: line, base: base, outside: ranges, pairs: &pairs, secrets: &secrets)
        }

        pairs.sort { $0.order < $1.order }
        secrets.sort { ($0.tier, $0.order) < ($1.tier, $1.order) }
        var seen = Set<String>()
        secrets = secrets
            .filter { !$0.value.isEmpty && !placeholders.contains($0.value.lowercased()) }
            .filter { seen.insert($0.value).inserted }

        // Read in order of strength: the line after a bare keyword, then a
        // paste that is nothing but the password. A Chinese phrase read from
        // the space after a label does not count yet — it is the password
        // only when nothing else is.
        let strong = secrets.filter { $0.tier < CaptureRules.phraseTier }
        readAfterKeywordLine(lines: lines, labeled: strong, secrets: &secrets)
        if strong.isEmpty {
            readBare(raw: trimmed, pairs: pairs, secrets: &secrets)
        }
        secrets.sort { ($0.tier, $0.order) < ($1.tier, $1.order) }

        if secrets.contains(where: { $0.tier < CaptureRules.phraseTier }) {
            let setAside = Set(secrets.filter { $0.tier == CaptureRules.phraseTier }.map(\.value))
            secrets.removeAll { $0.tier == CaptureRules.phraseTier }
            for index in pairs.indices where setAside.contains(pairs[index].value) {
                pairs[index].isSecret = false
            }
        }

        // No labeled value may carry a secret: not one that quotes a URI, and
        // not one the paste glued to the password that followed it.
        pairs = pairs.map { pair in
            guard !pair.isSecret else { return pair }
            var next = pair
            next.value = scrub(pair.value, secrets: secrets)
            return next
        }

        return CaptureReading(
            raw: trimmed,
            lines: lines,
            text: normalize(trimmed),
            pairs: pairs,
            secrets: secrets,
            uris: uris
        )
    }

    /// Whitespace-normalized to a single line, with one pair of surrounding
    /// quotes dropped.
    static func normalize(_ text: String) -> String {
        var normalized = text
            .replacingOccurrences(of: #"\\\s*[\r\n]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[\r\n\t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if (normalized.hasPrefix("\"") && normalized.hasSuffix("\""))
            || (normalized.hasPrefix("'") && normalized.hasSuffix("'"))
            || (normalized.hasPrefix("`") && normalized.hasSuffix("`")) {
            normalized.removeFirst()
            normalized.removeLast()
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: URIs

    @discardableResult
    private static func readURIs(
        in line: String, base: Int,
        pairs: inout [CapturePair], secrets: inout [CapturedSecret], uris: inout [CaptureURI]
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        for match in uriPattern.all(in: line) {
            guard let whole = CapturePattern.group(line, match, 0) else { continue }
            let shown = trimURI(dropTrailingPunctuation(whole))
            let range = NSRange(location: match.range.location, length: (shown as NSString).length)
            guard let uri = parseURI(shown, range: range) else { continue }
            ranges.append(range)
            uris.append(uri)

            let order = base + match.range.location
            var slot = 0
            func add(_ key: String, _ value: String?, _ source: CapturePair.Source, rawKey: String? = nil, isSecret: Bool = false, tier: Int = CaptureRules.otherSecretTier) {
                guard let value, !value.isEmpty else { return }
                let written = rawKey ?? key
                pairs.append(CapturePair(key: key, rawKey: written, value: value, source: source, order: order + slot, isSecret: isSecret))
                if isSecret {
                    secrets.append(CapturedSecret(key: key, rawKey: written, value: value, source: source, tier: tier, order: order + slot))
                }
                slot += 1
            }

            if let password = uri.password {
                secrets.append(CapturedSecret(key: "password", rawKey: "\(uri.scheme)://", value: password, source: .uri, tier: CaptureRules.credentialTier, order: order))
            }
            add("username", uri.username, .uri, rawKey: "\(uri.scheme)://")
            add("host", uri.host, .uri, rawKey: "\(uri.scheme)://")
            add("port", uri.port, .uri, rawKey: "\(uri.scheme)://")
            add(resourceKey(for: uri.scheme), uri.resource, .uri, rawKey: "\(uri.scheme)://")
            add("bucket", uri.scheme.lowercased() == "s3" ? uri.host : nil, .uri, rawKey: "s3")
            add("engine", engine(for: uri.scheme), .uri, rawKey: "\(uri.scheme)://")
            add("url", uri.clean, .uri, rawKey: "\(uri.scheme)://")
            for parameter in uri.parameters {
                add(parameter.key, parameter.value, .uriParameter, rawKey: parameter.rawKey, isSecret: parameter.isSecret, tier: CaptureRules.credentialTier)
            }
        }
        return ranges
    }

    /// Where a URI run really ends. Everything before the authority's first
    /// `/` is kept as it is — a raw `#`, `?` or Chinese punctuation can sit
    /// inside a password ("postgres://ro:SalesBI2026，北斗！@host/db"). After
    /// it, the URI ends where prose begins ("…/0，请及时修改"); and when the
    /// URI has no path and no userinfo, it ends at the first such character.
    static func trimURI(_ run: String) -> String {
        guard let schemeEnd = run.range(of: "://") else { return run }
        let rest = run[schemeEnd.upperBound...]
        func proseStart(_ text: Substring) -> String.Index? {
            text.firstIndex(where: { !$0.isASCII })
        }
        guard let slash = rest.firstIndex(of: "/") else {
            let stop = rest.firstIndex(where: { $0 == "?" || $0 == "#" })
            let at = rest.lastIndex(of: "@")
            if let at, stop.map({ at < $0 }) ?? true {
                // userinfo: the host after the `@` is ASCII
                let hostPort = rest[rest.index(after: at)...]
                guard let cut = proseStart(hostPort) else { return run }
                return run[..<cut].description
            }
            guard let cut = proseStart(rest) else { return run }
            return run[..<cut].description
        }
        let tail = rest[slash...]
        guard let cut = proseStart(tail) else { return run }
        return run[..<cut].description
    }

    /// Takes a URI apart. The authority ends at the first `/`, because a raw
    /// `#` or `?` can sit inside a password; an authority-only URI
    /// (`https://host?email=a@b.com`) has no userinfo when a `?` or `#` comes
    /// before the `@`.
    static func parseURI(_ text: String, range: NSRange = NSRange(location: 0, length: 0)) -> CaptureURI? {
        guard let schemeEnd = text.range(of: "://") else { return nil }
        let scheme = text[..<schemeEnd.lowerBound].lowercased()
        let rest = text[schemeEnd.upperBound...]

        var authority: Substring
        var remainder: Substring
        if let slash = rest.firstIndex(of: "/") {
            authority = rest[..<slash]
            remainder = rest[slash...]
        } else if let stop = rest.firstIndex(where: { $0 == "?" || $0 == "#" }), let at = rest.lastIndex(of: "@"), at > stop {
            authority = rest[..<stop]
            remainder = rest[stop...]
        } else if let stop = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            authority = rest[..<stop]
            remainder = rest[stop...]
        } else {
            authority = rest
            remainder = rest[rest.startIndex..<rest.startIndex]
        }

        var username: String?
        var password: String?
        var hostPort = authority
        if let at = authority.lastIndex(of: "@") {
            let userinfo = authority[..<at]
            hostPort = authority[authority.index(after: at)...]
            if let colon = userinfo.firstIndex(of: ":") {
                if !userinfo.isEmpty, colon != userinfo.startIndex {
                    username = CaptureRules.decoded(String(userinfo[..<colon]))
                }
                password = CaptureRules.decoded(String(userinfo[userinfo.index(after: colon)...]))
            } else if !userinfo.isEmpty {
                username = CaptureRules.decoded(String(userinfo))
            }
        }

        var host: String?
        var port: String?
        if !hostPort.isEmpty {
            if hostPort.hasPrefix("["), let close = hostPort.firstIndex(of: "]") {
                host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
                if hostPort.index(after: close) < hostPort.endIndex, hostPort[hostPort.index(after: close)] == ":" {
                    port = String(hostPort[hostPort.index(close, offsetBy: 2)...])
                }
            } else if let colon = hostPort.lastIndex(of: ":"), colon != hostPort.startIndex {
                host = String(hostPort[..<colon])
                port = String(hostPort[hostPort.index(after: colon)...])
            } else {
                host = String(hostPort)
            }
            if let value = port, !value.allSatisfy(\.isNumber) {
                port = nil
                host = String(hostPort)
            }
        }

        var path = ""
        var query = ""
        if !remainder.isEmpty {
            let fragmentless = remainder.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            if let question = fragmentless.firstIndex(of: "?") {
                path = String(fragmentless[..<question])
                query = String(fragmentless[fragmentless.index(after: question)...])
            } else {
                path = String(fragmentless)
            }
        }
        let firstSegment = path.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init)
        var resource: String?
        if let firstSegment {
            switch scheme {
            case "redis", "rediss":
                resource = firstSegment.allSatisfy(\.isNumber) ? firstSegment : nil
            case "http", "https", "s3", "oss", "gs":
                resource = nil
            default:
                resource = firstSegment
            }
        }

        let parts = query.split(whereSeparator: { $0 == "&" || $0 == ";" })
        var parameters: [CaptureURIParameter] = []
        var shownParts: [String] = []
        for part in parts {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = pieces.first, !rawKey.isEmpty else { continue }
            let value = pieces.count > 1 ? CaptureRules.decoded(String(pieces[1])) : ""
            let isSecret = CaptureRules.isSecretKey(String(rawKey))
            parameters.append(CaptureURIParameter(key: CaptureRules.canonicalKey(String(rawKey)), rawKey: String(rawKey), value: value, isSecret: isSecret))
            shownParts.append(isSecret ? "\(rawKey)=[REDACTED]" : String(part))
        }

        // The storable form: no userinfo, secret-class parameters blanked.
        var clean = "\(scheme)://\(hostPort)\(path)"
        if !shownParts.isEmpty {
            clean += "?" + shownParts.joined(separator: "&")
        }

        return CaptureURI(
            scheme: scheme, clean: clean, range: range,
            username: username, password: password, host: host, port: port, resource: resource, parameters: parameters
        )
    }

    private static func resourceKey(for scheme: String) -> String {
        switch scheme.lowercased() {
        case "redis", "rediss": return "db"
        case "amqp", "amqps": return "vhost"
        default: return "database"
        }
    }

    private static func engine(for scheme: String) -> String? {
        switch scheme.lowercased() {
        case "postgresql", "postgres": return "postgres"
        case "mysql", "mariadb", "clickhouse", "mongodb", "mssql", "oracle": return scheme.lowercased()
        default: return nil
        }
    }

    private static func dropTrailingPunctuation(_ text: String) -> String {
        var result = text
        while let last = result.last, ")]},;:\"'>".contains(last) {
            result.removeLast()
        }
        return result
    }

    // MARK: Key / value pairs

    /// A `.pgpass` line has no labels: `host:port:database:user:password`.
    private static func readPgpass(
        in line: String, base: Int, pairs: inout [CapturePair], secrets: inout [CapturedSecret]
    ) -> Bool {
        guard let match = pgpassPattern.first(in: line),
              let host = CapturePattern.group(line, match, 1), let port = CapturePattern.group(line, match, 2),
              let database = CapturePattern.group(line, match, 3), let user = CapturePattern.group(line, match, 4),
              let password = CapturePattern.group(line, match, 5), !password.isEmpty else { return false }

        for (key, value) in [("host", host), ("port", port), ("database", database), ("username", user)] where !value.isEmpty {
            pairs.append(CapturePair(key: key, rawKey: key, value: value, source: .keyValue, order: base, isSecret: false))
        }
        if !isStandIn(password) {
            pairs.append(CapturePair(key: "password", rawKey: "pgpass", value: password, source: .keyValue, order: base, isSecret: true))
            secrets.append(CapturedSecret(key: "password", rawKey: "pgpass", value: password, source: .keyValue, tier: CaptureRules.credentialTier, order: base))
        }
        return true
    }

    private static func readPairs(
        in line: String, base: Int, outside ranges: [NSRange],
        pairs: inout [CapturePair], secrets: inout [CapturedSecret]
    ) {
        let nsLine = line as NSString
        var cursor = 0

        while cursor < nsLine.length, let match = pairPattern.first(in: line, from: cursor) {
            guard let writtenKey = CapturePattern.group(line, match, 1), let rawValue = CapturePattern.group(line, match, 2) else { return }
            let keyRange = match.range(at: 1)
            let valueRange = match.range(at: 2)
            let rawKey = dropQuotes(writtenKey)

            // Inside a URI, or `scheme://…` itself: not a pair.
            if ranges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) || schemePrefixPattern.first(in: rawValue) != nil {
                cursor = NSMaxRange(keyRange) + 1
                continue
            }
            // `host:port` and addresses before a bare colon are not labels.
            let separator = nsLine.substring(with: NSRange(location: NSMaxRange(keyRange), length: valueRange.location - NSMaxRange(keyRange)))
            if separator == ":",
               addressKeyPattern.first(in: rawKey) != nil || hostPortPattern.first(in: "\(rawKey):\(rawValue)") != nil {
                cursor = NSMaxRange(match.range)
                continue
            }

            let isSecret = CaptureRules.isSecretKey(rawKey)
            // A value that stands for "the secret goes here" (`${DB_PASSWORD}`,
            // `$(vault read …)`) is a reference, not a secret. A command
            // substitution is skipped whole: what it prints is not in the paste.
            if isSecret, !isQuoted(rawValue), referencePattern.first(in: rawValue) != nil {
                cursor = nsLine.length
                if rawValue.hasPrefix("$("), let close = line.lastIndex(of: ")") {
                    cursor = min(cursor, nsLine.length - line[close...].utf16.count + 1)
                }
                continue
            }
            // A pair glued inside a value (`Environment=POSTGRES_PASSWORD=…`)
            // is read from where it starts, not as the outer pair's value.
            if !isSecret, !isQuoted(rawValue), leadingPairPattern.first(in: rawValue) != nil,
               let inner = pairPattern.first(in: rawValue), inner.range.location == 0,
               let innerKey = CapturePattern.group(rawValue, inner, 1), CaptureRules.isSecretKey(dropQuotes(innerKey)) {
                cursor = valueRange.location
                continue
            }
            guard valueRange.length > 0, var (value, consumed) = trimmedValue(rawValue, isSecret: isSecret) else {
                // Resume inside the value: what was cut off may hold the next pair.
                cursor = valueRange.location + 1
                continue
            }
            // Resume right after the value, so what was cut off is read in turn.
            cursor = valueRange.location + max(consumed, 1)
            // A value that stands for "the secret goes here" is not one.
            if isSecret, isStandIn(value, key: rawKey) { continue }

            // `Authorization: Bearer <token>`: the token is the secret; the
            // scheme word stays in the text.
            if isSecret, authSchemeWords.contains(value.lowercased()) {
                let tail = nsLine.substring(from: NSMaxRange(valueRange))
                if let schemeTail = authSchemeTailPattern.first(in: tail), let token = CapturePattern.group(tail, schemeTail, 1), !isStandIn(token) {
                    value = token
                    consumed = schemeTail.range.length + NSMaxRange(valueRange) - valueRange.location
                    cursor = valueRange.location + consumed
                }
            }

            // An app password goes on after a space: "abcd efgh ijkl mnop".
            if isSecret, value.count == 4, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                let tail = nsLine.substring(from: NSMaxRange(valueRange))
                if let groups = appPasswordTailPattern.first(in: tail), let joined = CapturePattern.group(tail, groups, 0) {
                    value += joined
                    consumed += (joined as NSString).length
                    cursor = valueRange.location + consumed
                }
            }

            let key = CaptureRules.canonicalKey(rawKey)
            let order = base + match.range.location
            pairs.append(CapturePair(key: key, rawKey: rawKey, value: value, source: .keyValue, order: order, isSecret: isSecret))
            if isSecret {
                secrets.append(
                    CapturedSecret(key: key, rawKey: rawKey, value: value, source: .keyValue, tier: CaptureRules.tier(canonicalKey: key, rawKey: rawKey), order: order)
                )
            }
        }
    }

    /// A value that stands for "the secret goes here" rather than being the
    /// secret: a placeholder, a reference to a variable, a remark.
    private static func isStandIn(_ value: String, key: String? = nil) -> Bool {
        let lowered = value.lowercased()
        if placeholders.contains(lowered) || referencePattern.first(in: value) != nil || notValues.contains(lowered) { return true }
        // A path under a file/path label is not itself a password. The label
        // remains secret-class, so an actual secret under it stays concealed.
        if let key, key.lowercased().contains("file") || key.lowercased().contains("path"), value.hasPrefix("/") {
            return true
        }
        return value.allSatisfy(CaptureRules.isCJK) && hanStandIns.contains(where: value.contains)
    }

    /// The value of an unquoted pair ends where the next pair starts and at
    /// the punctuation that closes a sentence; for a secret it also ends where
    /// a sentence in Chinese continues after it. Returns the value and how
    /// many UTF-16 units of the raw value it occupies. Nil when nothing is left.
    /// Whether a value was written in quotes of any kind.
    private static func isQuoted(_ value: String) -> Bool {
        guard value.count >= 2, let first = value.first, let last = value.last else { return false }
        return (first == last && "\"'`".contains(first)) || (first == "“" && last == "”") || (first == "‘" && last == "’")
    }

    private static func trimmedValue(_ rawValue: String, isSecret: Bool) -> (value: String, consumed: Int)? {
        if isQuoted(rawValue) {
            let inner = String(rawValue.dropFirst().dropLast())
            return inner.isEmpty ? nil : (inner, (rawValue as NSString).length)
        }

        let nsValue = rawValue as NSString
        var cut = nsValue.length
        if let next = nextPairPattern.first(in: rawValue) {
            cut = next.range.location
        }
        if isSecret {
            let head = nsValue.substring(to: cut)
            cut = head.prefix(secretPrefixLength(head)).utf16.count
        }
        var kept = nsValue.substring(to: cut)
        while let last = kept.last, last == "。" || "\"'`,;:".contains(last) {
            kept.removeLast()
        }
        while let last = kept.last, CaptureRules.closingBrackets.contains(last),
              kept.filter(CaptureRules.closingBrackets.contains).count > kept.filter(CaptureRules.openingBrackets.contains).count {
            kept.removeLast()
        }
        return kept.isEmpty ? nil : (kept, (kept as NSString).length)
    }

    /// How much of a value is the secret, in characters.
    ///
    /// A secret written in Latin script ends where Chinese prose begins — but
    /// not when a short flourish is part of it ("FrontDesk2026，欢迎来访！" is
    /// one password; "LQ2026-…，首次登录后必须立即修改为新密码" is a password
    /// followed by instructions). A secret written in Chinese ends at the
    /// first word with which a sentence would go on.
    static func secretPrefixLength(_ value: String) -> Int {
        let characters = Array(value)
        func isCJKOrStop(_ character: Character) -> Bool {
            CaptureRules.isCJK(character) || cjkStops.contains(character) || CaptureRules.openingBrackets.contains(character)
        }
        guard let restStart = characters.firstIndex(where: isCJKOrStop) else { return characters.count }
        let rest = Array(characters[restStart...])
        let hasCore = restStart > 0

        // A remark in brackets is never part of the secret.
        if hasCore, let first = rest.first, CaptureRules.openingBrackets.contains(first) {
            return restStart
        }
        if hasCore, let first = rest.first, cjkStops.contains(first) {
            return isClause(Array(rest.dropFirst())) ? restStart : characters.count
        }
        if hasCore {
            return proseOnset(in: rest, from: 0) == 0 ? restStart : characters.count
        }
        // The value starts with punctuation: not much of a secret.
        if let first = rest.first, cjkStops.contains(first) || CaptureRules.openingBrackets.contains(first) {
            return characters.count
        }
        if let onset = proseOnset(in: rest, from: 2) {
            return restStart + onset
        }
        return characters.count
    }

    /// Whether a stretch of Chinese is a clause rather than a flourish.
    private static func isClause(_ tail: [Character]) -> Bool {
        var body = tail
        while let last = body.last, cjkStops.contains(last) {
            body.removeLast()
        }
        if body.contains(where: { cjkStops.contains($0) || CaptureRules.openingBrackets.contains($0) }) {
            return true
        }
        return body.filter(CaptureRules.isCJK).count > 6
    }

    /// The first position at or after `minimum` where a sentence goes on: a
    /// sentence word followed by at least two more Chinese characters.
    private static func proseOnset(in characters: [Character], from minimum: Int) -> Int? {
        guard characters.count > minimum else { return nil }
        for index in minimum ..< characters.count {
            for onset in proseOnsets {
                let word = Array(onset)
                let afterOnset = index + word.count
                guard afterOnset <= characters.count,
                      Array(characters[index ..< afterOnset]) == word else { continue }
                let following = characters[afterOnset...]
                if following.count >= 2, following.prefix(2).allSatisfy(CaptureRules.isCJK) {
                    return index
                }
            }
        }
        return nil
    }

    // MARK: Command-line flags

    private static func readCommandFlags(
        in line: String, base: Int, outside ranges: [NSRange],
        pairs: inout [CapturePair], secrets: inout [CapturedSecret]
    ) {
        func isFree(_ match: NSTextCheckingResult) -> Bool {
            !ranges.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
        }

        // `curl -u user:password`: the password rides along with the username.
        for match in cliUserPattern.all(in: line) where isFree(match) {
            guard let flag = CapturePattern.group(line, match, 0), let value = CapturePattern.group(line, match, 1) else { continue }
            let order = base + match.range.location
            let unquoted = dropQuotes(value)
            if let colon = unquoted.firstIndex(of: ":") {
                let user = String(unquoted[..<colon])
                let password = String(unquoted[unquoted.index(after: colon)...])
                if !user.isEmpty {
                    pairs.append(CapturePair(key: "username", rawKey: flag, value: user, source: .commandFlag, order: order, isSecret: false))
                }
                if !password.isEmpty, !isStandIn(password) {
                    pairs.append(CapturePair(key: "password", rawKey: flag, value: password, source: .commandFlag, order: order, isSecret: true))
                    secrets.append(CapturedSecret(key: "password", rawKey: flag, value: password, source: .commandFlag, tier: CaptureRules.credentialTier, order: order))
                }
            } else {
                pairs.append(CapturePair(key: "username", rawKey: flag, value: unquoted, source: .commandFlag, order: order, isSecret: false))
            }
        }
        for match in cliSecretPattern.all(in: line) + cliShortPasswordPattern.all(in: line) + cliGluedPasswordPattern.all(in: line) where isFree(match) {
            guard let flag = CapturePattern.group(line, match, 0), let rawValue = CapturePattern.group(line, match, 1) else { continue }
            let value = dropQuotes(rawValue)
            guard !value.isEmpty, !isStandIn(value) else { continue }
            let order = base + match.range.location
            pairs.append(CapturePair(key: "password", rawKey: flag, value: value, source: .commandFlag, order: order, isSecret: true))
            secrets.append(CapturedSecret(key: "password", rawKey: flag, value: value, source: .commandFlag, tier: CaptureRules.credentialTier, order: order))
        }
    }

    // MARK: Natural language

    private static func readNaturalLanguage(
        in line: String, base: Int, outside ranges: [NSRange],
        pairs: inout [CapturePair], secrets: inout [CapturedSecret]
    ) {
        var taken: [NSRange] = []

        /// Reads every match of `pattern`: group 1 is the label, group 2 the value.
        func record(_ pattern: CapturePattern, isSecret: Bool, weak: Bool = false) {
            for match in pattern.all(in: line) {
                guard let label = CapturePattern.group(line, match, 1), let rawValue = CapturePattern.group(line, match, 2) else { continue }
                let wholeRange = match.range
                guard !ranges.contains(where: { NSIntersectionRange($0, wholeRange).length > 0 }),
                      !taken.contains(where: { NSIntersectionRange($0, wholeRange).length > 0 }) else { continue }

                var value = isSecret ? String(rawValue.prefix(secretPrefixLength(rawValue))) : rawValue
                while let last = value.last, last == "。" || "\"'`,;:".contains(last) {
                    value.removeLast()
                }
                // "密码是：x": the separator belongs to the label.
                while isSecret, let first = value.first, ":：=＝".contains(first) {
                    value.removeFirst()
                }
                // A Chinese value from a sentence is the password only when it
                // is a phrase and nothing else in the paste is (its tier says
                // so); a remark about the password is not a candidate at all.
                let phrase = isSecret && isChinesePhrase(value)
                guard !value.isEmpty, !notValues.contains(value.lowercased()),
                      !isSecret || !placeholders.contains(value.lowercased()),
                      !value.allSatisfy(CaptureRules.isCJK) || phrase,
                      !weak || !isSecret || phrase || looksLikeCredential(value) else { continue }
                taken.append(wholeRange)

                let key = CaptureRules.canonicalKey(label)
                let order = base + wholeRange.location
                pairs.append(CapturePair(key: key, rawKey: label, value: value, source: .naturalLanguage, order: order, isSecret: isSecret))
                if isSecret {
                    // A sentence is weaker evidence than a label with a
                    // separator, and a value read from the space after the
                    // label is weaker still: a labeled value elsewhere in the
                    // paste always wins over either.
                    let base = CaptureRules.tier(canonicalKey: key, rawKey: label)
                    let tier = phrase ? CaptureRules.phraseTier : min(base + (weak ? 2 : 1), CaptureRules.unlabeledTier)
                    secrets.append(CapturedSecret(key: key, rawKey: label, value: value, source: .naturalLanguage, tier: tier, order: order))
                }
            }
        }

        for pattern in nlCopulaPatterns {
            record(pattern, isSecret: true)
        }
        record(nlSpacePattern, isSecret: true, weak: true)
        record(nlGluedPattern, isSecret: true)
        record(nlAccessKeyPattern, isSecret: false)
        record(nlUserIsPattern, isSecret: false)
    }

    /// Whether what follows a secret label across a space can be the secret:
    /// something shaped like a credential, or a short Chinese phrase (which
    /// `CaptureRules.phraseTier` sets apart until the paste is fully read).
    private static func looksLikeCredential(_ value: String) -> Bool {
        guard value.count >= 6 else { return false }
        let hasSymbol = value.contains { !$0.isLetter && !$0.isNumber }
        let hasUppercase = value.contains { $0.isASCII && $0.isUppercase }
        let hasLowercase = value.contains { $0.isASCII && $0.isLowercase }
        return value.contains(where: { $0.isASCII && $0.isNumber }) || hasSymbol || (hasUppercase && hasLowercase)
    }

    /// A run of Chinese characters long enough to be a password — three
    /// characters at least, "token 在 1Password 里" is not one. Whether it is
    /// one cannot be read off the text: "已发送到邮箱" is as much a phrase as
    /// "幸福快乐每一天". So a phrase is set apart by its tier and kept only
    /// when the paste holds no other secret.
    private static func isChinesePhrase(_ value: String) -> Bool {
        (3 ... 20).contains(value.count) && value.allSatisfy(CaptureRules.isCJK) && !hanProseMarkers.contains(where: value.contains)
    }

    // MARK: No label, or a label on its own line

    private static func isCredential(_ candidate: String) -> Bool {
        candidate.split(whereSeparator: { $0.isWhitespace }).count == 1
            && candidate.count <= 72
            && candidate.contains { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func cleaned(_ value: String) -> String? {
        let trimmed = dropQuotes(value).trimmingCharacters(in: CharacterSet(charactersIn: "。"))
        guard !trimmed.isEmpty, trimmed != "[REDACTED]", !placeholders.contains(trimmed.lowercased()) else { return nil }
        return trimmed
    }

    /// A line that ends on a secret label; the secret itself follows on the
    /// next line. It ranks as the login password unless the paste already has
    /// a labeled password or a URI credential — then it is only a candidate.
    private static func readAfterKeywordLine(lines: [String], labeled: [CapturedSecret], secrets: inout [CapturedSecret]) {
        let hasStrong = labeled.contains { $0.tier <= CaptureRules.credentialTier }
        for (index, line) in lines.enumerated() {
            guard keywordTailPattern.first(in: line) != nil, !isDetailLine(line), lines.indices.contains(index + 1) else { continue }
            let candidate = lines[index + 1]
            guard isCredential(candidate), keywordTailPattern.first(in: candidate) == nil, !isDetailLine(candidate),
                  let value = cleaned(candidate), !secrets.contains(where: { $0.value == value }) else { continue }
            secrets.append(
                CapturedSecret(
                    key: "password", rawKey: "", value: value, source: .naturalLanguage,
                    tier: hasStrong ? CaptureRules.unlabeledTier : CaptureRules.passwordTier,
                    order: 1_000_000_000 + index
                )
            )
        }
    }

    /// The paste is the password and nothing else: "hg_6688@2026", or
    /// "商城名 hg_6688@2026".
    ///
    /// A paste that has a labeled value in it is never read this way, whatever
    /// is left over (`PublicKey=ssh-rsa AAAA…`), and neither is a run of
    /// Chinese: a sentence with an English word in it is still a sentence.
    private static func readBare(raw: String, pairs: [CapturePair], secrets: inout [CapturedSecret]) {
        func add(_ value: String) {
            guard let value = cleaned(value) else { return }
            secrets.append(CapturedSecret(key: "password", rawKey: "", value: value, source: .naturalLanguage, tier: CaptureRules.unlabeledTier, order: 2_000_000_000))
        }
        func isBareCredential(_ token: String) -> Bool {
            looksLikeCredential(token) && !token.contains(where: CaptureRules.isCJK)
        }

        guard pairs.isEmpty, !raw.contains("://"), !raw.contains(where: { ":：=＝".contains($0) }) else { return }
        let tokens = raw.split(separator: " ").map(String.init)
        if tokens.count == 1 {
            if isBareCredential(raw) {
                add(raw)
            }
        } else if tokens.count == 2 {
            // "商城名 hg_6688@2026", "彩虹健身App登录码 Jk8$Yu3@Wv6": a name
            // that is mostly Chinese, and the credential. Two Latin words are
            // not this (`ssh-ed25519 AAAA…`).
            func isCJKName(_ token: String) -> Bool {
                token.filter(CaptureRules.isCJK).count > token.filter { $0.isASCII && $0.isLetter }.count
            }
            guard let name = tokens.first(where: isCJKName),
                  let credential = tokens.first(where: { $0 != name }), isBareCredential(credential) else { return }
            add(credential)
        }
    }

    /// Whether a line is one detail of a larger paste — a `key: value` pair
    /// or a URI — rather than free prose such as a heading.
    static func isDetailLine(_ line: String) -> Bool {
        if line.contains("://") { return true }
        guard let match = pairPattern.first(in: line), let key = CapturePattern.group(line, match, 1) else { return false }
        return key.contains(where: { $0.isLetter || CaptureRules.isCJK($0) })
    }

    // MARK: Scrubbing

    private static let userinfoPattern = CapturePattern(#"\b([a-z][a-z0-9+.\-]*://)[^/\s?\"'<>]+@"#, .caseInsensitive)
    private static let uriParameterPattern = CapturePattern(#"([?&;])([^=?&#\s]+)=([^&#\s]*)"#)

    private static func dropQuotes(_ value: String) -> String {
        var result = value
        while let first = result.first, "\"'`“”‘’".contains(first) { result.removeFirst() }
        while let last = result.last, "\"'`“”‘’".contains(last) { result.removeLast() }
        return result
    }

    /// The text with every secret taken out: URI userinfo removed, secret-class
    /// URI parameters blanked, and each secret replaced in either of its
    /// spellings. Idempotent — scrubbing a scrubbed text changes nothing.
    /// Scrub one known secret as well as the structural secret shapes. This is
    /// used by editor reclassification, where the secret is already in its own
    /// field rather than in the synthesized text.
    static func scrub(_ text: String, secret: String?) -> String {
        guard let secret, !secret.isEmpty else { return scrub(text) }
        return scrub(text, secrets: [
            CapturedSecret(key: "password", rawKey: "", value: secret, source: .keyValue, tier: CaptureRules.passwordTier, order: 0),
        ])
    }

    static func scrub(_ text: String, secrets: [CapturedSecret] = []) -> String {
        var result = ""
        var cursor = 0
        let ns = text as NSString
        var edits: [(NSRange, String)] = []
        for match in userinfoPattern.all(in: text) {
            guard let scheme = CapturePattern.group(text, match, 1) else { continue }
            edits.append((match.range, scheme))
        }
        for match in uriParameterPattern.all(in: text) {
            guard let separator = CapturePattern.group(text, match, 1), let key = CapturePattern.group(text, match, 2),
                  CaptureRules.isSecretKey(key), CapturePattern.group(text, match, 3)?.isEmpty == false else { continue }
            edits.append((match.range, "\(separator)\(key)=[REDACTED]"))
        }
        edits.sort { $0.0.location < $1.0.location }
        for (range, replacement) in edits where range.location >= cursor {
            result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor)) + replacement
            cursor = NSMaxRange(range)
        }
        result += ns.substring(from: cursor)

        var forms = Set(secrets.flatMap { CaptureRules.encodedForms(of: $0.value) })
        forms.remove("")
        for form in forms.sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: form, with: "[REDACTED]")
        }
        return result
    }
}
