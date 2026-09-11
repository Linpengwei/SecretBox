import Foundation

enum SignalCategory: String, Codable, Hashable {
    case locator
    case principal
    case resource
    case context
    case secret
}

struct VaultSignal: Codable, Hashable, Identifiable {
    var id: String { "\(category.rawValue):\(name):\(normalizedValue)" }
    var category: SignalCategory
    var name: String
    var value: String
    var normalizedValue: String
}

enum CredentialClusterID: String, Codable, Hashable, CaseIterable {
    case humanAccountLogin = "human_account_login"
    case serviceEndpointSecret = "service_endpoint_secret"
    case relationalDBCredential = "relational_db_credential"
    case cacheCredential = "cache_credential"
    case messageQueueCredential = "message_queue_credential"
    case objectStorageCredential = "object_storage_credential"
    case cloudAccessPair = "cloud_access_pair"
    case genericSecretNote = "generic_secret_note"
}

struct ClusterSchemaField: Codable, Hashable {
    var label: String
    var keys: [String]
}

struct ClusterSchemaDefinition: Codable, Hashable {
    var title: String
    var fields: [ClusterSchemaField]
}

extension CredentialClusterID {
    var schemaDefinition: ClusterSchemaDefinition {
        switch self {
        case .humanAccountLogin:
            return ClusterSchemaDefinition(
                title: "Account Access",
                fields: [
                    ClusterSchemaField(label: "Account", keys: ["account", "username"]),
                    ClusterSchemaField(label: "Service", keys: ["label", "service"]),
                    ClusterSchemaField(label: "URL", keys: ["url", "endpoint"]),
                    ClusterSchemaField(label: "Environment", keys: ["env"])
                ]
            )
        case .serviceEndpointSecret:
            return ClusterSchemaDefinition(
                title: "Service Access",
                fields: [
                    ClusterSchemaField(label: "Endpoint", keys: ["endpoint", "url", "host"]),
                    ClusterSchemaField(label: "Principal", keys: ["username", "account"]),
                    ClusterSchemaField(label: "Environment", keys: ["env"]),
                    ClusterSchemaField(label: "Provider", keys: ["provider"])
                ]
            )
        case .relationalDBCredential:
            return ClusterSchemaDefinition(
                title: "Database Access",
                fields: [
                    ClusterSchemaField(label: "Engine", keys: ["engine"]),
                    ClusterSchemaField(label: "Host", keys: ["host", "endpoint"]),
                    ClusterSchemaField(label: "Database", keys: ["database"]),
                    ClusterSchemaField(label: "Principal", keys: ["username"]),
                    ClusterSchemaField(label: "Environment", keys: ["env"])
                ]
            )
        case .cacheCredential:
            return ClusterSchemaDefinition(
                title: "Cache Access",
                fields: [
                    ClusterSchemaField(label: "Host", keys: ["host", "url"]),
                    ClusterSchemaField(label: "Database", keys: ["database", "db"]),
                    ClusterSchemaField(label: "Principal", keys: ["username"]),
                    ClusterSchemaField(label: "Environment", keys: ["env"])
                ]
            )
        case .messageQueueCredential:
            return ClusterSchemaDefinition(
                title: "Queue Access",
                fields: [
                    ClusterSchemaField(label: "Transport", keys: ["brokers", "vhost", "host"]),
                    ClusterSchemaField(label: "Resource", keys: ["topic", "queue", "vhost"]),
                    ClusterSchemaField(label: "Mechanism", keys: ["mechanism"]),
                    ClusterSchemaField(label: "Principal", keys: ["username"]),
                    ClusterSchemaField(label: "Environment", keys: ["env"])
                ]
            )
        case .objectStorageCredential:
            return ClusterSchemaDefinition(
                title: "Object Storage Access",
                fields: [
                    ClusterSchemaField(label: "Provider", keys: ["provider"]),
                    ClusterSchemaField(label: "Endpoint", keys: ["endpoint", "url"]),
                    ClusterSchemaField(label: "Bucket", keys: ["bucket"]),
                    ClusterSchemaField(label: "Access Key", keys: ["access_key"]),
                    ClusterSchemaField(label: "Region", keys: ["region"])
                ]
            )
        case .cloudAccessPair:
            return ClusterSchemaDefinition(
                title: "Cloud Access Pair",
                fields: [
                    ClusterSchemaField(label: "Provider", keys: ["provider"]),
                    ClusterSchemaField(label: "Access Key", keys: ["access_key"]),
                    ClusterSchemaField(label: "Scope", keys: ["scope", "project"]),
                    ClusterSchemaField(label: "Region", keys: ["region"])
                ]
            )
        case .genericSecretNote:
            return ClusterSchemaDefinition(
                title: "Custom Secret Pattern",
                fields: [
                    ClusterSchemaField(label: "Locator", keys: ["host", "url", "endpoint", "brokers"]),
                    ClusterSchemaField(label: "Resource", keys: ["database", "bucket", "topic", "vhost", "scope", "project"]),
                    ClusterSchemaField(label: "Context", keys: ["label", "service", "env", "provider", "engine"])
                ]
            )
        }
    }
}

struct ClusterDecision: Codable, Hashable {
    var clusterID: CredentialClusterID
    var confidence: Double
    var reasons: [String]
}

struct OrganizationRunSummary: Codable, Hashable {
    var trigger: String
    var processedRecords: Int
    var customRecords: Int
    var reclusteredRecords: Int
    var promotedRecords: Int
    var generatedClusters: Int
    var ranAt: Date
}

struct ProviderSettingsViewData: Codable {
    var configured: Bool
    var baseURL: String?
    var model: String?
}

// MARK: - TOTP (Bitwarden Integrated Authenticator equivalent)

/// HMAC variant for RFC 6238 code generation. Raw values match the server's
/// algorithm whitelist and the `otpauth://` `algorithm=` parameter.
enum TOTPAlgorithm: String, Codable, Hashable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"
}

/// TOTP seed attached to a record. The base32 secret is secret-class data —
/// same handling rules as `primarySecret`: never rendered in AI-readable
/// contexts, never stored server-side outside `totp_encrypted` ciphertext,
/// never shown in plaintext in the detail UI. Codes are generated locally
/// only; the server just stores and returns the seed.
struct TOTPSecret: Codable, Hashable {
    var secret: String
    var issuer: String? = nil
    var account: String? = nil
    var digits: Int = 6
    var period: Int = 30
    var algorithm: TOTPAlgorithm = .sha1
}

// MARK: - Record permissions (Bitwarden-style granular access control)

/// AI agent access level for a record, generalizing the legacy boolean
/// `aiReadable` flag. `.none` keeps the MCP invariant: the record is
/// indistinguishable from a missing one.
enum AIAccessLevel: String, Codable, Hashable, CaseIterable {
    case none
    case metadata
    case metadataAndTools = "metadata_and_tools"
}

/// Reserved for Phase 2 multi-user sharing (Bitwarden-style per-subject
/// grants over users/groups/agents once the server has real authentication).
struct PermissionSubject: Codable, Hashable {
    var id: String
    var kind: String
    var access: AIAccessLevel
}

/// Per-record permission matrix. Mirrors Bitwarden's granular access
/// semantics for the subjects that exist today (local user + AI agents):
/// read-only, hide-passwords (usable but never visible), master-re-prompt
/// (biometric re-authentication before secret use), and leveled AI access.
struct RecordPermissions: Codable, Hashable {
    var readOnly: Bool = false
    var hideSecret: Bool = false
    var requireReauth: Bool = false
    var aiAccess: AIAccessLevel = .none
    var subjects: [PermissionSubject]? = nil
}

struct ProviderSettingsPayload: Codable {
    var baseURL: String
    var apiKey: String
    var model: String
}

struct VaultField: Codable, Hashable, Identifiable {
    var id: String { "\(section ?? "")::\(key)::\(order)" }
    var key: String
    var label: String
    var value: String
    var valueType: String
    var semantic: String?
    var hidden: Bool
    var section: String?
    var order: Int
}

struct VaultItemCreateRequest: Codable {
    var itemType: String
    var templateType: String?
    var name: String
    var pastedText: String
    var primarySecret: String?
    var notes: String
    var tags: [String]
    var fields: [VaultField]
    var totp: TOTPSecret? = nil
    /// Server-only flag for updates: explicit `true` clears the stored seed;
    /// omitting it keeps the existing one (same semantics as `primarySecret`).
    var removeTOTP: Bool? = nil
    var permissions: RecordPermissions? = nil

    init(itemType: String,
         templateType: String?,
         name: String,
         pastedText: String,
         primarySecret: String?,
         notes: String,
         tags: [String],
         fields: [VaultField],
         totp: TOTPSecret? = nil,
         removeTOTP: Bool? = nil,
         permissions: RecordPermissions? = nil) {
        self.itemType = itemType
        self.templateType = templateType
        self.name = name
        self.pastedText = pastedText
        self.primarySecret = primarySecret
        self.notes = notes
        self.tags = tags
        self.fields = fields
        self.totp = totp
        self.removeTOTP = removeTOTP
        self.permissions = permissions
    }
}

struct PasswordSearchRequest: Codable {
    var query: String
    var limit: Int
}

struct PasswordSearchResponse: Codable {
    var results: [VaultRecord]
}

struct VaultRecord: Codable, Identifiable, Hashable {
    var id: String
    var itemType: String
    var templateType: String?
    var clusterID: String? = nil
    var clusterConfidence: Double? = nil
    var signals: [VaultSignal]? = nil
    var clusterLabel: String? = nil
    var lastOrganizedAt: Date? = nil
    var name: String
    var subtitle: String?
    var notes: String
    var tags: [String]
    var fields: [VaultField]
    var passwordHash: String
    var passwordFingerprint: String
    var primarySecret: String?
    var matchReason: String?
    /// Opt-in flag: when true the record may be surfaced to AI agents (MCP).
    /// nil/false means NOT shared — the secure default for every record.
    /// Superseded by `permissions`; kept for decoding legacy local blobs.
    var aiReadable: Bool? = nil
    var totp: TOTPSecret? = nil
    var permissions: RecordPermissions? = nil

    /// Unified permission view. Records saved before the permission matrix
    /// only carry `aiReadable`; map it onto the leveled model (true meant
    /// metadata + clipboard tools, nil/false meant invisible to agents).
    var effectivePermissions: RecordPermissions {
        if let permissions { return permissions }
        var legacy = RecordPermissions()
        if aiReadable == true { legacy.aiAccess = .metadataAndTools }
        return legacy
    }

    var recordType: String { templateType ?? itemType }
    var title: String { name }
    var description: String { notes }
    var password: String? { primarySecret }
    var username: String? {
        fields.first(where: { $0.semantic == "username" || $0.key == "username" })?.value
    }
    var resolvedClusterID: CredentialClusterID? {
        guard let clusterID else { return nil }
        return CredentialClusterID(rawValue: clusterID)
    }
    var clusterSchemaDefinition: ClusterSchemaDefinition {
        resolvedClusterID?.schemaDefinition ?? CredentialClusterID.genericSecretNote.schemaDefinition
    }
    var fieldMap: [String: String] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })
    }
    var groupedFields: [(title: String, fields: [VaultField])] {
        let grouped = Dictionary(grouping: fields) { field in field.section ?? "Details" }
        return grouped.keys.sorted().map { title in
            (title, grouped[title, default: []].sorted { $0.order < $1.order })
        }
    }
}

extension VaultRecord {
    /// Clipboard snippet the user pastes into an AI agent chat *instead of*
    /// the plaintext password. It identifies the record unambiguously (so an
    /// agent with the SecretBox MCP server resolves it by id, no fuzzy
    /// search) and carries only the same redacted metadata the MCP server
    /// exposes — never `primarySecret` or other secret-classified fields.
    var aiAgentReference: String {
        var attributes = [
            "id=\"\(Self.xmlEscaped(id))\"",
            "name=\"\(Self.xmlEscaped(name))\"",
            "type=\"\(Self.xmlEscaped(recordType))\"",
        ]
        if let username, !username.isEmpty {
            attributes.append("username=\"\(Self.xmlEscaped(username))\"")
        }
        if let endpoint = aiReferenceEndpoint, !endpoint.isEmpty {
            attributes.append("host=\"\(Self.xmlEscaped(endpoint))\"")
        }

        return """
        <secretbox-credential \(attributes.joined(separator: " "))>
        Resolve with the SecretBox MCP server: get_credential(record_id="\(id)") for redacted details, copy_password(record_id="\(id)") to place the secret on the clipboard. The plaintext secret is intentionally not included — never ask me to paste it.
        </secretbox-credential>
        """
    }

    /// Connection hint for the reference. Mirrors the MCP redact whitelist:
    /// only endpoint-style metadata keys are eligible.
    private var aiReferenceEndpoint: String? {
        for key in ["url", "endpoint", "host", "brokers"] {
            if let signal = signals?.first(where: { $0.name == key }), !signal.value.isEmpty {
                return signal.value
            }
            if let value = fieldMap[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

struct VaultBrowserFilter: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
}

struct ClusterBrowserSummary: Identifiable, Hashable {
    let id: String
    let label: String
    let title: String
    let count: Int
    let highlights: [String]
    let latestActivityAt: Date?
    let recencyRank: Int
}

enum ClusterBrowserSortMode: String, Codable, CaseIterable, Hashable, Identifiable {
    case count
    case recent
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .count:
            return "Count"
        case .recent:
            return "Recent"
        case .name:
            return "Name"
        }
    }
}

struct CredentialType: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let itemType: String
    let fields: [TemplateField]
}

struct TemplateField: Hashable {
    let key: String
    let label: String
    let valueType: String
    let semantic: String?
    let section: String
}

struct PastedSecretPreview: Hashable {
    var templateType: String
    var clusterDecision: ClusterDecision
    var signals: [VaultSignal]
    var tags: [String]
    var highlights: [String]
    var hasSecret: Bool
    var editableFields: [PastedPreviewField]
    var hasTOTP: Bool = false
}

struct PastedPreviewField: Hashable, Identifiable {
    var id: String { key }
    var key: String
    var label: String
    var value: String
}
