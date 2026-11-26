import Foundation

// What a paste is, and which fields describe it: the second half of the
// capture engine. `CaptureExtraction` reads the paste; this turns the reading
// into signals, a cluster, a template and a field list.
//
// The scoring rules here predate the engine. They were moved, not rewritten:
// the 50-sample classifier regression and the golden corpus hold them to their
// recorded decisions.

nonisolated enum CaptureClassification {
    // MARK: Lookups

    private static let usernameKeys = ["username", "user", "account", "login", "email", "sasl_username", "aws_access_key_id"]
    private static let hostKeys = ["host", "hostname"]
    private static let portKeys = ["port"]
    private static let databaseKeys = ["database", "dbname", "db"]
    private static let urlKeys = ["url", "uri", "dsn", "site_url", "database_url", "jdbc_url", "redis_url"]
    private static let endpointKeys = ["endpoint", "s3_endpoint"]
    private static let regionKeys = ["region", "aws_default_region"]
    private static let scopeKeys = ["scope", "project", "tenant"]
    private static let redisDatabaseKeys = ["db", "database"]
    private static let engineKeys = ["engine", "driver"]

    /// Keys every lookup reads. A pair under one of these keys is already part
    /// of the record and is not added again as a free-form field.
    static let consumedKeys: Set<String> = [
        "username", "user", "account", "login", "email", "sasl_username", "aws_access_key_id",
        "host", "hostname", "port", "database", "dbname", "db",
        "url", "uri", "dsn", "site_url", "database_url", "jdbc_url", "redis_url", "endpoint", "s3_endpoint",
        "region", "aws_default_region", "scope", "project", "tenant",
        "engine", "driver", "provider", "cloud", "service", "site", "app", "cluster",
        "label", "env", "environment", "namespace", "stage", "mechanism", "sasl_mechanism",
        "brokers", "bootstrap_servers", "bootstrap", "topic", "queue", "bucket", "access_key", "ak",
        "name", "notes", "item_label",
    ]

    static func lookup(_ keyValues: [String: String], _ keys: [String]) -> String? {
        for key in keys {
            if let value = keyValues[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }

    // MARK: URL helpers

    static func host(from candidate: String?) -> String? {
        guard let candidate, !candidate.isEmpty else { return nil }
        if let host = URL(string: candidate)?.host, !host.isEmpty {
            return host
        }
        // URIs with unencoded characters in the userinfo make URL(string:) lose
        // the host; parse the authority textually instead.
        guard let schemeEnd = candidate.range(of: "://") else { return nil }
        let rest = candidate[schemeEnd.upperBound...]
        let authority = rest.prefix { !$0.isWhitespace && $0 != "/" && $0 != "?" }
        guard !authority.isEmpty else { return nil }
        if let at = authority.lastIndex(of: "@") {
            let hostPort = authority[authority.index(after: at)...]
            let host = hostPort.prefix { $0 != ":" && $0 != "#" }
            return host.isEmpty ? nil : String(host)
        }
        let host = authority.prefix { $0 != ":" && $0 != "#" }
        return host.isEmpty ? nil : String(host)
    }

    static func resourcePath(from candidate: String?) -> String? {
        guard let candidate, !candidate.isEmpty,
              let components = URLComponents(string: candidate) else {
            return nil
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? nil : path
    }

    static func scheme(of candidate: String?) -> String? {
        guard let candidate, !candidate.isEmpty,
              let scheme = URLComponents(string: candidate)?.scheme else {
            return nil
        }
        return scheme.lowercased()
    }

    static func databaseEngine(in lowered: String) -> String? {
        for engine in ["postgres", "postgresql", "mysql", "mariadb", "clickhouse", "oracle", "sqlserver", "mongodb"] {
            if lowered.contains(engine) {
                return engine == "postgresql" ? "postgres" : engine
            }
        }
        return nil
    }

    // MARK: Signals

    /// Where a labeled secret was found, for the `secret_carrier` signal.
    static func secretCarrier(labels: Set<String>, hasURICredential: Bool) -> String {
        let prioritized = [
            "password", "passwd", "pwd", "secret", "secret_key", "token",
            "sk", "sasl_password", "api_key", "apikey", "aws_secret_access_key",
        ]
        if let matched = prioritized.first(where: { labels.contains($0) }) {
            return matched
        }
        if hasURICredential {
            return "inline_uri_auth"
        }
        return "freeform_secret"
    }

    static func normalizedSignalValue(name: String, value: String) -> String {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch name {
        case "url", "endpoint":
            if let host = URL(string: value)?.host?.lowercased(), !host.isEmpty {
                return host
            }
            return lowered
        default:
            return lowered
        }
    }

    private static let databaseSchemes: Set<String> = [
        "postgres", "postgresql", "mysql", "mariadb", "clickhouse", "mongodb", "mssql", "oracle", "jdbc", "db2", "sybase",
    ]

    /// Words for object storage in a paste, and those that name a bucket: a
    /// bucket makes it an object-storage credential, a secret key under
    /// "对象存储" alone is read as an access-key pair.
    private static let storageWords = ["对象存储", "存储桶", "素材桶"]
    private static let bucketWords = ["存储桶", "素材桶", "归档桶", "存档桶", "备份桶", "桶"]

    static func signals(text: String, keyValues: [String: String], labels: Set<String>, secret: String?, hasURICredential: Bool) -> [VaultSignal] {
        var signals: [VaultSignal] = []

        func append(_ category: SignalCategory, _ name: String, _ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let normalized = normalizedSignalValue(name: name, value: trimmed)
            guard !normalized.isEmpty else { return }
            signals.append(VaultSignal(category: category, name: name, value: trimmed, normalizedValue: normalized))
        }

        let explicitURL = lookup(keyValues, urlKeys)
        let endpointURL = lookup(keyValues, endpointKeys)
        let detectedURL = detectedURL(in: text)

        append(.locator, "url", explicitURL ?? detectedURL)
        append(.locator, "endpoint", endpointURL)
        append(.locator, "host", lookup(keyValues, hostKeys) ?? host(from: explicitURL ?? endpointURL ?? detectedURL))
        append(.locator, "brokers", lookup(keyValues, ["brokers", "bootstrap_servers", "bootstrap"]))
        append(.locator, "port", lookup(keyValues, portKeys))

        append(.principal, "username", lookup(keyValues, ["username", "user", "login", "sasl_username"]))
        append(.principal, "account", lookup(keyValues, ["account", "email"]))
        append(.principal, "access_key", lookup(keyValues, ["access_key", "ak", "aws_access_key_id"]))

        // Only a database URI's path names a database; the path of a web
        // address (`https://host/login`) is a page, not a database.
        let databaseURL = [explicitURL, detectedURL].compactMap { $0 }.first { databaseSchemes.contains(scheme(of: $0) ?? "") }
        append(.resource, "database", lookup(keyValues, databaseKeys) ?? resourcePath(from: databaseURL))
        append(.resource, "bucket", lookup(keyValues, ["bucket"]))
        append(.resource, "topic", lookup(keyValues, ["topic", "queue"]))
        append(.resource, "scope", lookup(keyValues, scopeKeys))
        append(.resource, "project", lookup(keyValues, ["project"]))
        append(.resource, "vhost", lookup(keyValues, ["vhost"]) ?? (scheme(of: explicitURL ?? detectedURL) == "amqp" ? resourcePath(from: explicitURL ?? detectedURL) : nil))

        append(.context, "service", lookup(keyValues, ["service", "site", "app", "cluster"]))
        append(.context, "label", lookup(keyValues, ["label"]))
        append(.context, "env", lookup(keyValues, ["env", "environment", "namespace", "stage"]))
        append(.context, "region", lookup(keyValues, regionKeys))
        append(.context, "provider", lookup(keyValues, ["provider", "cloud"]))
        append(.context, "engine", lookup(keyValues, engineKeys) ?? databaseEngine(in: text.lowercased()))
        append(.context, "mechanism", lookup(keyValues, ["mechanism", "sasl_mechanism"]))

        if let secret, !secret.isEmpty {
            append(.secret, "secret_present", "true")
            append(.secret, "secret_carrier", secretCarrier(labels: labels, hasURICredential: hasURICredential))
            append(.secret, "secret_suffix", String(secret.suffix(min(4, secret.count))))
        }

        return deduplicated(signals)
    }

    private static func detectedURL(in text: String) -> String? {
        CaptureParser.firstCapture(in: text, pattern: #"((?:https?|rediss|redis|postgresql|postgres|mysql|mariadb|clickhouse|mongodb|amqp)://[^\s]+)"#)
    }

    static func deduplicated(_ signals: [VaultSignal]) -> [VaultSignal] {
        var seen: [String: VaultSignal] = [:]
        for signal in signals {
            seen[signal.id] = signal
        }
        return seen.values.sorted { lhs, rhs in
            if lhs.category != rhs.category {
                return lhs.category.rawValue < rhs.category.rawValue
            }
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.normalizedValue < rhs.normalizedValue
        }
    }

    // MARK: Cluster

    /// Most specific cluster first; `genericSecretNote` is last so it only
    /// wins when nothing else scored.
    static let clusterTieBreakOrder: [CredentialClusterID] = [
        .cacheCredential, .relationalDBCredential, .messageQueueCredential, .objectStorageCredential,
        .cloudAccessPair, .humanAccountLogin, .serviceEndpointSecret, .genericSecretNote,
    ]

    /// Scores every cluster from the signals and picks the best. Ties go to
    /// the more specific cluster, in a fixed order: collection iteration order
    /// is randomized per process launch and must never decide where a record
    /// is filed. A paste with no recognizable signal stays unclassified.
    static func decideCluster(for signals: [VaultSignal], text: String, keyValues: [String: String]) -> ClusterDecision {
        func has(_ name: String, in category: SignalCategory? = nil) -> Bool {
            signals.contains { signal in
                signal.name == name && (category == nil || signal.category == category)
            }
        }

        let lowered = text.lowercased()
        let hasWebURL = lowered.contains("https://") || lowered.contains("http://")
        let hasDatabaseScheme = lowered.contains("postgresql://")
            || lowered.contains("postgres://")
            || lowered.contains("mysql://")
            || lowered.contains("mariadb://")
            || lowered.contains("clickhouse://")
            || lowered.contains("mongodb://")
        let hasExplicitEndpointKey = keyValues.keys.contains("endpoint")
            || keyValues.keys.contains("s3_endpoint")
        let hasExplicitLoginKey = keyValues.keys.contains("login")

        var scores: [CredentialClusterID: Int] = [:]
        var reasons: [CredentialClusterID: [String]] = [:]

        func add(_ cluster: CredentialClusterID, _ points: Int, _ reason: String) {
            scores[cluster, default: 0] += points
            reasons[cluster, default: []].append(reason)
        }

        if has("account", in: .principal) { add(.humanAccountLogin, 30, "account") }
        if has("username", in: .principal) { add(.humanAccountLogin, 10, "username") }
        if hasWebURL { add(.humanAccountLogin, 20, "web-url") }
        if hasWebURL && (has("service", in: .context) || has("label", in: .context)) { add(.humanAccountLogin, 25, "service") }
        if hasWebURL && has("account", in: .principal) {
            add(.humanAccountLogin, 20, "service-url")
        }

        if has("host", in: .locator) || has("endpoint", in: .locator) { add(.serviceEndpointSecret, 20, "endpoint") }
        if has("username", in: .principal) { add(.serviceEndpointSecret, 15, "principal") }
        // A secret by itself is not evidence of a service endpoint. Without a
        // locator or principal the record must remain a generic secret note.
        if has("secret_present", in: .secret), has("host", in: .locator) || has("endpoint", in: .locator) || has("url", in: .locator) {
            add(.serviceEndpointSecret, 10, "secret")
        }
        if hasExplicitEndpointKey { add(.serviceEndpointSecret, 25, "explicit-endpoint-key") }
        if hasExplicitLoginKey { add(.serviceEndpointSecret, 20, "explicit-login-key") }

        if has("engine", in: .context) { add(.relationalDBCredential, 25, "engine") }
        if has("database", in: .resource) { add(.relationalDBCredential, 25, "database") }
        if has("host", in: .locator) { add(.relationalDBCredential, 15, "host") }
        if has("username", in: .principal) { add(.relationalDBCredential, 10, "username") }
        if hasDatabaseScheme { add(.relationalDBCredential, 25, "database-scheme") }

        if lowered.contains("redis://") { add(.cacheCredential, 45, "redis-uri") }
        else if lowered.contains("redis") { add(.cacheCredential, 35, "redis") }
        if has("database", in: .resource) { add(.cacheCredential, 10, "db") }
        if has("host", in: .locator) { add(.cacheCredential, 10, "host") }

        if has("brokers", in: .locator) { add(.messageQueueCredential, 30, "brokers") }
        if has("topic", in: .resource) || has("vhost", in: .resource) { add(.messageQueueCredential, 25, "resource") }
        if has("mechanism", in: .context) { add(.messageQueueCredential, 15, "auth-mechanism") }
        if lowered.contains("amqp://") || lowered.contains("rabbitmq") || keyValues["engine"] == "rabbitmq" { add(.messageQueueCredential, 30, "amqp") }

        if has("bucket", in: .resource) { add(.objectStorageCredential, 30, "bucket") }
        if has("endpoint", in: .locator) { add(.objectStorageCredential, 20, "endpoint") }
        if has("access_key", in: .principal) { add(.objectStorageCredential, 20, "access-key") }
        if has("bucket", in: .resource) && has("access_key", in: .principal) {
            add(.objectStorageCredential, 30, "bucket-with-access-key")
        }

        if has("provider", in: .context) { add(.cloudAccessPair, 20, "provider") }
        if has("access_key", in: .principal) { add(.cloudAccessPair, 20, "access-key") }
        if has("scope", in: .resource) || has("project", in: .resource) { add(.cloudAccessPair, 15, "scope") }

        var bestCluster = CredentialClusterID.genericSecretNote
        var bestScore = 0
        for cluster in clusterTieBreakOrder {
            let score = scores[cluster, default: 0]
            if score > bestScore {
                bestScore = score
                bestCluster = cluster
            }
        }
        let confidence = min(0.99, max(0.2, Double(bestScore) / 90.0))
        let finalReasons = reasons[bestCluster, default: []]
        return ClusterDecision(clusterID: bestCluster, confidence: confidence, reasons: Array(finalReasons.prefix(4)))
    }

    // MARK: Template

    /// The template is what the paste names, read directly (the server's
    /// rules), with two additions. A secret that sits inside a URI names its
    /// own service by the URI's scheme: in a paste with several credentials
    /// the record follows the one picked as the secret. And when nothing
    /// names the kind at all, the cluster stands in.
    ///
    /// - Parameter secretScheme: the scheme of the URI the primary secret came
    ///   from ("postgresql://"), nil when it came from a label.
    static func templateType(
        for clusterDecision: ClusterDecision, text: String, keyValues: [String: String], labels: Set<String>, secretScheme: String?
    ) -> String {
        if let template = secretScheme.flatMap(template(forSecretScheme:)) {
            return template
        }
        let detected = detectTemplateType(in: text, keyValues: keyValues, labels: labels)
        guard detected == "custom" else { return detected }

        let lowered = text.lowercased()
        switch clusterDecision.clusterID {
        case .messageQueueCredential:
            return lowered.contains("kafka") || keyValues.keys.contains("brokers") || keyValues.keys.contains("bootstrap_servers") ? "kafka" : "custom"
        case .cloudAccessPair:
            return keyValues.keys.contains("bucket") || keyValues.keys.contains("s3_endpoint") ? "s3" : "aksk"
        default:
            return "custom"
        }
    }

    /// The template a URI scheme with a password in it names. A web address
    /// or any other scheme leaves the decision to the paste.
    static func template(forSecretScheme scheme: String) -> String? {
        switch scheme.lowercased() {
        case "redis", "rediss": return "redis"
        case "postgres", "postgresql", "mysql", "mariadb", "clickhouse", "mongodb", "mongodb+srv", "mssql", "oracle", "jdbc": return "database"
        case "s3", "s3a", "s3n": return "s3"
        default: return nil
        }
    }

    private static let databaseTokens = [
        "postgres", "mysql", "mariadb", "clickhouse", "oracle", "sqlserver", "jdbc:", "mongodb",
        "数据库", "只读库", "主库", "从库", "数仓",
    ]
    /// S3 as a word, not as the start of a password ("S3cureAtlas!").
    private static let s3WordPattern = CapturePattern(#"(?<![a-z0-9])s3(?![a-z0-9])"#)
    private static let accountMarkers = [
        "网站", "网址", "登录", "登陆", "后台", "门户", "账号", "帐号", "账户", "邮箱", "用户名", "平台", "地址",
    ]
    private static let signInPagePattern = CapturePattern(#"://[^/\s]+/[^?\s]*(?:signin|sign-in|sign_in|login|logon)"#)
    private static let emailPattern = CapturePattern(#"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#)
    /// Keys that say the paste describes a piece of infrastructure, where an
    /// e-mail address is a contact and not the login.
    private static let infrastructureKeys: Set<String> = [
        "host", "hostname", "port", "endpoint", "s3_endpoint", "url", "uri", "brokers", "bucket", "engine", "region", "server",
    ]

    /// Rules in the order the server parser applies them, with the client's
    /// additions kept: Chinese markers for object storage, databases and
    /// accounts, the spellings of an access-key pair, and a sign-in page.
    ///
    /// `text` is the paste as the user wrote it. A bare GitHub token is the
    /// only evidence of its own kind, so scrubbing first would hide it. The
    /// text is only read here; what is stored is scrubbed elsewhere.
    static func detectTemplateType(in text: String, keyValues: [String: String], labels: Set<String>) -> String {
        let lowered = text.lowercased()
        let keys = Set(keyValues.keys)

        if lowered.contains("amqp://") || lowered.contains("rabbitmq") || keys.contains("vhost") {
            return "custom"
        }
        if lowered.contains("redis://") || lowered.contains("redis") {
            return "redis"
        }
        // A `topic` key alone is not a queue: the subject of a mail is one too.
        if lowered.contains("kafka") || keys.contains("brokers") || keys.contains("bootstrap_servers")
            || labels.contains("sasl_password") || lowered.contains("zookeeper")
            || (keys.contains("topic") && ["kafka", "broker", "sasl", "consumer", "producer", "队列"].contains(where: lowered.contains)) {
            return "kafka"
        }
        if s3WordPattern.first(in: lowered) != nil || keys.contains("bucket") || keys.contains("s3_endpoint")
            || (labels.contains("aws_access_key_id") && labels.contains("aws_secret_access_key"))
            || bucketWords.contains(where: lowered.contains) {
            return "s3"
        }
        if databaseTokens.contains(where: lowered.contains) || keys.contains("database") || keys.contains("dbname")
            || (keys.contains("engine") && keyValues["engine"] != "rabbitmq") {
            return "database"
        }
        let hasSecretKey = labels.contains("secret_key") || labels.contains("sk") || labels.contains("secret_access_key")
        let hasAccessKey = keys.contains("access_key") || keys.contains("ak") || labels.contains("access_key_id") || keys.contains("aws_access_key_id")
        let compact = lowered.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
        if (hasAccessKey && hasSecretKey) || compact.contains("accesskey")
            || (lowered.contains("access key") && lowered.contains("secret"))
            || (hasSecretKey && storageWords.contains(where: lowered.contains)) {
            return "aksk"
        }
        // A password next to an e-mail address is a login, unless the paste
        // describes infrastructure, where the address is whom to contact.
        let isLogin = ["password", "passwd", "pwd"].contains(where: labels.contains)
            && keyValues.values.contains { emailPattern.first(in: $0) != nil }
            && infrastructureKeys.isDisjoint(with: keys)
        if lowered.contains("github") || lowered.contains("gitlab") || lowered.contains("slack") || lowered.contains("account") || lowered.contains("login")
            || keys.contains("service") || keys.contains("account") || keys.contains("email")
            || accountMarkers.contains(where: lowered.contains)
            || signInPagePattern.first(in: lowered) != nil
            || isLogin {
            return "account"
        }
        return inferredType(in: lowered)
    }

    private static func inferredType(in lowered: String) -> String {
        if lowered.contains("redis") { return "redis" }
        if lowered.contains("kafka") || lowered.contains("brokers=") { return "kafka" }
        if lowered.contains("bucket") || lowered.contains("s3") || lowered.contains("access_key") { return "s3" }
        if lowered.contains("postgres") || lowered.contains("mysql") || lowered.contains("database") || lowered.contains("jdbc:") { return "database" }
        if lowered.contains("github") || lowered.contains("account") || lowered.contains("login") { return "account" }
        return "custom"
    }

    // MARK: Fields

    private static let redisURIPattern = CapturePattern(#"redis://(?:(?:([^:@/\s]+):)?([^@/\s]+)@)?([^:/\s]+):(\d+)(?:/(\d+))?"#, .caseInsensitive)
    private static let amqpURIPattern = CapturePattern(#"amqp://(?:(?:([^:@/\s]+):)?([^@/\s]+)@)?([^:/\s]+):(\d+)(?:/([^\s]+))?"#, .caseInsensitive)
    private static let numberKeys: Set<String> = ["port"]
    private static let urlKeyNames: Set<String> = ["url", "uri", "dsn", "endpoint"]

    static func field(_ key: String, _ label: String, _ value: String, type: String = "text", semantic: String? = nil, section: String, order: Int, hidden: Bool = false) -> VaultField {
        VaultField(key: key, label: label, value: value, valueType: type, semantic: semantic, hidden: hidden, section: section, order: order)
    }

    /// The fields of a template, plus the context every template shares.
    /// `text` is the scrubbed paste: URIs in it carry no credentials.
    static func fields(templateType: String, text: String, keyValues: [String: String]) -> [VaultField] {
        var fields: [VaultField]
        switch templateType {
        case "redis":
            fields = redisFields(text, keyValues: keyValues)
        case "database":
            fields = databaseFields(text, keyValues: keyValues)
        case "s3":
            fields = objectStorageFields(keyValues)
        case "kafka":
            fields = kafkaFields(keyValues)
        case "aksk":
            fields = keyPairFields(keyValues)
        case "account":
            fields = accountFields(keyValues)
        case "custom":
            fields = text.lowercased().contains("amqp://") || text.lowercased().contains("rabbitmq") || keyValues.keys.contains("vhost")
                ? rabbitMQFields(text, keyValues: keyValues)
                : []
        default:
            fields = []
        }

        fields = withContext(fields, text: text, keyValues: keyValues)

        if let username = lookup(keyValues, usernameKeys), !fields.contains(where: { $0.key == "username" }) {
            fields.insert(field("username", "Username", username, semantic: "username", section: "Auth", order: 0), at: 0)
        }
        return fields
    }

    private static func redisFields(_ text: String, keyValues: [String: String]) -> [VaultField] {
        var fields: [VaultField] = []
        if let match = redisURIPattern.first(in: text), let groups = CaptureParser.groups(in: text, match) {
            let whole = (text as NSString).substring(with: match.range)
            if let username = groups[0], !username.isEmpty {
                fields.append(field("username", "Username", username, semantic: "username", section: "Auth", order: 0))
            }
            fields.append(field("host", "Host", groups[2] ?? "", semantic: "host", section: "Connection", order: 1))
            fields.append(field("port", "Port", groups[3] ?? "", type: "number", semantic: "port", section: "Connection", order: 2))
            if let db = groups[4], !db.isEmpty {
                fields.append(field("db", "Database", db, type: "number", semantic: "database", section: "Connection", order: 3))
            }
            fields.append(field("url", "URL", whole, type: "url", semantic: "uri", section: "Connection", order: 4))
            return fields
        }

        if let host = lookup(keyValues, hostKeys) {
            fields.append(field("host", "Host", host, semantic: "host", section: "Connection", order: 1))
        }
        if let port = lookup(keyValues, portKeys) {
            fields.append(field("port", "Port", port, type: "number", semantic: "port", section: "Connection", order: 2))
        }
        if let db = lookup(keyValues, redisDatabaseKeys) {
            fields.append(field("db", "Database", db, type: "number", semantic: "database", section: "Connection", order: 3))
        }
        if let url = lookup(keyValues, ["url", "redis_url"]) {
            fields.append(field("url", "URL", url, type: "url", semantic: "uri", section: "Connection", order: 4))
        }
        return fields
    }

    private static func databaseFields(_ text: String, keyValues: [String: String]) -> [VaultField] {
        var fields: [VaultField] = []
        let engine = lookup(keyValues, engineKeys) ?? databaseEngine(in: text.lowercased())
        if let engine {
            fields.append(field("engine", "Engine", engine, semantic: "engine", section: "Connection", order: 1))
        }

        var urlValue = lookup(keyValues, urlKeys + endpointKeys)
        if urlValue == nil {
            urlValue = CaptureParser.firstCapture(in: text, pattern: #"((?:postgresql|postgres|mysql|mariadb|clickhouse|mongodb)://[^\s]+)"#)
        }

        if let host = lookup(keyValues, hostKeys) {
            fields.append(field("host", "Host", host, semantic: "host", section: "Connection", order: 2))
        }
        if let port = lookup(keyValues, portKeys) {
            fields.append(field("port", "Port", port, type: "number", semantic: "port", section: "Connection", order: 3))
        }
        if let database = lookup(keyValues, databaseKeys) {
            fields.append(field("database", "Database", database, semantic: "database", section: "Connection", order: 4))
        }

        if let urlValue, let components = URLComponents(string: urlValue) {
            if let host = components.host, !fields.contains(where: { $0.key == "host" }) {
                fields.append(field("host", "Host", host, semantic: "host", section: "Connection", order: 2))
            }
            if let port = components.port, !fields.contains(where: { $0.key == "port" }) {
                fields.append(field("port", "Port", String(port), type: "number", semantic: "port", section: "Connection", order: 3))
            }
            let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !path.isEmpty, !fields.contains(where: { $0.key == "database" }) {
                fields.append(field("database", "Database", path, semantic: "database", section: "Connection", order: 4))
            }
            if let username = components.user, !fields.contains(where: { $0.key == "username" }) {
                fields.append(field("username", "Username", username, semantic: "username", section: "Auth", order: 0))
            }
        }

        return fields
    }

    /// One field per key, last write wins, in a fixed order. `key` breaks the
    /// remaining ties: collection order is randomized per process launch and
    /// must not decide the stored field order.
    static func deduplicated(_ fields: [VaultField]) -> [VaultField] {
        var seen: [String: VaultField] = [:]
        for field in fields {
            seen[field.key] = field
        }
        return seen.values.sorted { lhs, rhs in
            (lhs.section ?? "", lhs.order, lhs.label, lhs.key) < (rhs.section ?? "", rhs.order, rhs.label, rhs.key)
        }
    }

    private static func objectStorageFields(_ keyValues: [String: String]) -> [VaultField] {
        var fields: [VaultField] = []
        if let endpoint = lookup(keyValues, ["endpoint", "s3_endpoint", "url", "host"]) {
            fields.append(field("endpoint", "Endpoint", endpoint, type: "url", semantic: "endpoint", section: "Connection", order: 1))
        }
        if let bucket = lookup(keyValues, ["bucket"]) {
            fields.append(field("bucket", "Bucket", bucket, semantic: "bucket", section: "Connection", order: 2))
        }
        if let accessKey = lookup(keyValues, ["access_key", "ak", "aws_access_key_id"]) {
            fields.append(field("access_key", "Access Key", accessKey, semantic: "access_key", section: "Auth", order: 3))
        }
        if let region = lookup(keyValues, regionKeys) {
            fields.append(field("region", "Region", region, semantic: "region", section: "Connection", order: 4))
        }
        return fields
    }

    private static func kafkaFields(_ keyValues: [String: String]) -> [VaultField] {
        var fields: [VaultField] = []
        if let brokers = lookup(keyValues, ["brokers", "bootstrap_servers", "bootstrap"]) {
            fields.append(field("brokers", "Brokers", brokers, semantic: "brokers", section: "Connection", order: 1))
        }
        if let mechanism = lookup(keyValues, ["mechanism", "sasl_mechanism"]) {
            fields.append(field("mechanism", "Mechanism", mechanism, semantic: "mechanism", section: "Auth", order: 2))
        }
        if let topic = lookup(keyValues, ["topic"]) {
            fields.append(field("topic", "Topic", topic, semantic: "topic", section: "Connection", order: 3))
        }
        if let username = lookup(keyValues, ["sasl_username", "username", "user"]) {
            fields.append(field("username", "Username", username, semantic: "username", section: "Auth", order: 0))
        }
        return fields
    }

    private static func keyPairFields(_ keyValues: [String: String]) -> [VaultField] {
        var fields: [VaultField] = []
        if let provider = lookup(keyValues, ["provider", "cloud"]) {
            fields.append(field("provider", "Provider", provider, semantic: "provider", section: "Details", order: 1))
        }
        if let accessKey = lookup(keyValues, ["access_key", "ak"]) {
            fields.append(field("access_key", "Access Key", accessKey, semantic: "access_key", section: "Auth", order: 2))
        }
        if let scope = lookup(keyValues, scopeKeys) {
            fields.append(field("scope", "Scope", scope, semantic: "scope", section: "Details", order: 3))
        }
        if let region = lookup(keyValues, ["region"]) {
            fields.append(field("region", "Region", region, semantic: "region", section: "Details", order: 4))
        }
        return fields
    }

    private static func accountFields(_ keyValues: [String: String]) -> [VaultField] {
        var fields: [VaultField] = []
        if let service = lookup(keyValues, ["service", "site", "provider"]) {
            fields.append(field("service", "Service", service, semantic: "service", section: "Login", order: 1))
        }
        if let account = lookup(keyValues, ["account", "email", "user", "username"]) {
            fields.append(field("account", "Account", account, semantic: "account", section: "Login", order: 2))
        }
        if let url = lookup(keyValues, ["url", "site_url", "uri"]) {
            fields.append(field("url", "URL", url, type: "url", semantic: "uri", section: "Login", order: 3))
        }
        return fields
    }

    private static func rabbitMQFields(_ text: String, keyValues: [String: String]) -> [VaultField] {
        var fields: [VaultField] = []
        if let match = amqpURIPattern.first(in: text), let groups = CaptureParser.groups(in: text, match) {
            if let username = groups[0], !username.isEmpty {
                fields.append(field("username", "Username", username, semantic: "username", section: "Auth", order: 0))
            }
            if let host = groups[2], !host.isEmpty {
                fields.append(field("host", "Host", host, semantic: "host", section: "Connection", order: 1))
            }
            if let port = groups[3], !port.isEmpty {
                fields.append(field("port", "Port", port, type: "number", semantic: "port", section: "Connection", order: 2))
            }
            if let vhost = groups[4], !vhost.isEmpty {
                fields.append(field("vhost", "VHost", vhost, semantic: "vhost", section: "Connection", order: 3))
            }
            return fields
        }

        if let host = lookup(keyValues, hostKeys) {
            fields.append(field("host", "Host", host, semantic: "host", section: "Connection", order: 1))
        }
        if let port = lookup(keyValues, portKeys) {
            fields.append(field("port", "Port", port, type: "number", semantic: "port", section: "Connection", order: 2))
        }
        if let vhost = lookup(keyValues, ["vhost"]) {
            fields.append(field("vhost", "VHost", vhost, semantic: "vhost", section: "Connection", order: 3))
        }
        if let engine = lookup(keyValues, ["engine"]), !engine.isEmpty {
            fields.append(field("engine", "Engine", engine, semantic: "engine", section: "Details", order: 4))
        }
        return fields
    }

    /// The context every template shares: a URL, a label, an environment, a
    /// region and so on, each only when the template did not already supply it.
    private static func withContext(_ fields: [VaultField], text: String, keyValues: [String: String]) -> [VaultField] {
        var enriched = fields

        func appendIfMissing(_ key: String, _ label: String, _ value: String?, type: String = "text", semantic: String? = nil, section: String, order: Int) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard !enriched.contains(where: { $0.key == key }) else { return }
            // A URI username already represents the principal; a second
            // `account` field with the same value only hides useful context
            // from the short preview.
            if key == "account",
               let username = lookup(keyValues, ["username", "user", "login", "sasl_username"]), username == trimmed {
                return
            }
            enriched.append(field(key, label, trimmed, type: type, semantic: semantic, section: section, order: order))
        }

        let explicitURL = lookup(keyValues, urlKeys)
        let endpointURL = lookup(keyValues, endpointKeys)
        let detectedURL = detectedURL(in: text)
        appendIfMissing("url", "URL", explicitURL ?? detectedURL ?? endpointURL, type: "url", semantic: "uri", section: "Connection", order: 90)
        appendIfMissing("label", "Label", lookup(keyValues, ["label", "service", "site", "app", "cluster"]), semantic: "label", section: "Metadata", order: 91)
        appendIfMissing("env", "Environment", lookup(keyValues, ["env", "environment", "namespace", "stage"]), semantic: "environment", section: "Metadata", order: 92)
        appendIfMissing("region", "Region", lookup(keyValues, regionKeys), semantic: "region", section: "Metadata", order: 93)
        appendIfMissing("provider", "Provider", lookup(keyValues, ["provider", "cloud"]), semantic: "provider", section: "Metadata", order: 94)
        appendIfMissing("account", "Account", lookup(keyValues, ["account", "email", "login", "user", "username", "sasl_username"]), semantic: "account", section: "Auth", order: 95)
        appendIfMissing("database", "Database", lookup(keyValues, databaseKeys), semantic: "database", section: "Connection", order: 96)
        appendIfMissing("bucket", "Bucket", lookup(keyValues, ["bucket"]), semantic: "bucket", section: "Connection", order: 97)
        appendIfMissing("topic", "Topic", lookup(keyValues, ["topic", "queue"]), semantic: "topic", section: "Connection", order: 98)
        appendIfMissing("scope", "Scope", lookup(keyValues, scopeKeys), semantic: "scope", section: "Metadata", order: 99)
        appendIfMissing("host", "Host", lookup(keyValues, hostKeys) ?? host(from: explicitURL ?? endpointURL ?? detectedURL), semantic: "host", section: "Connection", order: 100)

        return enriched
    }

    /// Labeled values no template field stands for ("team=data"), and every
    /// secondary secret as a concealed field. A field key is used once: the
    /// order is (section, order, label, key), with `key` as the final tie-break
    /// because collection order is randomized per launch.
    static func complete(_ fields: [VaultField], pairs: [CapturePair], secondarySecrets: [CapturedSecret]) -> [VaultField] {
        var seen: [String: VaultField] = [:]
        for field in fields {
            seen[field.key] = field
        }

        var order = 1
        for pair in pairs where !pair.isSecret {
            guard !CaptureClassification.consumedKeys.contains(pair.key), !seen.keys.contains(pair.key), !pair.value.isEmpty else { continue }
            let type = numberKeys.contains(pair.key) ? "number" : (urlKeyNames.contains(pair.key) ? "url" : "text")
            // Whatever made the reader set this pair apart, a secret-class
            // key always conceals its value.
            let hidden = CaptureRules.isSecretKey(pair.key) || CaptureRules.isSecretKey(pair.rawKey)
            seen[pair.key] = field(
                pair.key, CaptureRules.displayLabel(pair.rawKey), pair.value,
                type: type, semantic: pair.key, section: "Details", order: order, hidden: hidden
            )
            order += 1
        }

        var index = 0
        for secret in secondarySecrets {
            var key = secret.key.isEmpty ? "secret" : secret.key
            var suffix = 2
            while seen.keys.contains(key) {
                key = "\(secret.key)_\(suffix)"
                suffix += 1
            }
            seen[key] = field(
                key, CaptureRules.displayLabel(secret.rawKey), secret.value,
                semantic: key, section: "Secrets", order: 900 + index, hidden: true
            )
            index += 1
        }

        return seen.values.sorted { lhs, rhs in
            (lhs.section ?? "", lhs.order, lhs.label, lhs.key) < (rhs.section ?? "", rhs.order, rhs.label, rhs.key)
        }
    }

    // MARK: Name and notes

    static func recordName(templateType: String, keyValues: [String: String], fields: [VaultField]) -> String {
        let target = lookup(keyValues, ["service", "bucket", "host", "database", "account", "provider"])
        if templateType == "database", let target {
            let engine = lookup(keyValues, engineKeys) ?? databaseEngine(in: keyValues.values.joined(separator: " ").lowercased())
            if let engine {
                return "\(engine.uppercased()) \(target)"
            }
        }
        if let target {
            return "\(templateType.uppercased()) \(target)"
        }
        if let host = fields.first(where: { $0.key == "host" })?.value {
            return "\(templateType.uppercased()) \(host)"
        }
        return templateType.uppercased()
    }

    static func notes(templateType: String, keyValues: [String: String], fallback: String?) -> String {
        let env = lookup(keyValues, ["env", "environment", "namespace"])
        let target = lookup(keyValues, ["service", "bucket", "database", "topic", "host"])
        let parts = [env, target].compactMap { $0 }
        if !parts.isEmpty {
            return "\(templateType.uppercased()) credential for \(parts.joined(separator: " / "))"
        }
        if let fallback, !fallback.isEmpty {
            return String(fallback.prefix(140))
        }
        return "\(templateType.uppercased()) credential"
    }
}
