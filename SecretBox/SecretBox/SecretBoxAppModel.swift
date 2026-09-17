#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Combine
import Foundation
import SwiftUI

@MainActor
final class SecretBoxAppModel: ObservableObject {
    private enum OrganizationTrigger: String {
        case threshold
        case periodic
        case manual
    }

    private struct ParsedLocalSecret {
        var itemType: String
        var templateType: String
        var clusterDecision: ClusterDecision
        var signals: [VaultSignal]
        var name: String
        var notes: String
        var tags: [String]
        var fields: [VaultField]
        var primarySecret: String?
    }

    static let supportedTypes: [CredentialType] = [
        CredentialType(id: "s3", title: "S3", systemImage: "externaldrive.fill.badge.icloud", itemType: "secret", fields: [
            TemplateField(key: "username", label: "Username", valueType: "text", semantic: "username", section: "Auth"),
            TemplateField(key: "endpoint", label: "Endpoint", valueType: "url", semantic: "endpoint", section: "Connection"),
            TemplateField(key: "bucket", label: "Bucket", valueType: "text", semantic: "bucket", section: "Connection"),
            TemplateField(key: "access_key", label: "Access Key", valueType: "text", semantic: "access_key", section: "Auth"),
            TemplateField(key: "region", label: "Region", valueType: "text", semantic: "region", section: "Connection"),
        ]),
        CredentialType(id: "account", title: "Account", systemImage: "person.crop.rectangle", itemType: "login", fields: [
            TemplateField(key: "username", label: "Username", valueType: "text", semantic: "username", section: "Login"),
            TemplateField(key: "service", label: "Service", valueType: "text", semantic: "service", section: "Login"),
            TemplateField(key: "account", label: "Account", valueType: "text", semantic: "account", section: "Login"),
            TemplateField(key: "url", label: "URL", valueType: "url", semantic: "uri", section: "Login"),
        ]),
        CredentialType(id: "aksk", title: "AK/SK", systemImage: "key.radiowaves.forward", itemType: "secret", fields: [
            TemplateField(key: "provider", label: "Provider", valueType: "text", semantic: "provider", section: "Details"),
            TemplateField(key: "access_key", label: "Access Key", valueType: "text", semantic: "access_key", section: "Auth"),
            TemplateField(key: "scope", label: "Scope", valueType: "text", semantic: "scope", section: "Details"),
        ]),
        CredentialType(id: "credit_card", title: "Credit Card", systemImage: "creditcard.fill", itemType: "card", fields: [
            TemplateField(key: "holder", label: "Holder", valueType: "text", semantic: "holder", section: "Card"),
            TemplateField(key: "bank", label: "Bank", valueType: "text", semantic: "bank", section: "Card"),
            TemplateField(key: "card_suffix", label: "Card Suffix", valueType: "text", semantic: "card_suffix", section: "Card"),
        ]),
        CredentialType(id: "redis", title: "Redis", systemImage: "shippingbox.fill", itemType: "secret", fields: [
            TemplateField(key: "username", label: "Username", valueType: "text", semantic: "username", section: "Auth"),
            TemplateField(key: "host", label: "Host", valueType: "text", semantic: "host", section: "Connection"),
            TemplateField(key: "port", label: "Port", valueType: "number", semantic: "port", section: "Connection"),
            TemplateField(key: "db", label: "Database", valueType: "number", semantic: "database", section: "Connection"),
            TemplateField(key: "url", label: "URL", valueType: "url", semantic: "uri", section: "Connection"),
        ]),
        CredentialType(id: "database", title: "Database", systemImage: "cylinder.fill", itemType: "secret", fields: [
            TemplateField(key: "username", label: "Username", valueType: "text", semantic: "username", section: "Auth"),
            TemplateField(key: "engine", label: "Engine", valueType: "text", semantic: "engine", section: "Connection"),
            TemplateField(key: "host", label: "Host", valueType: "text", semantic: "host", section: "Connection"),
            TemplateField(key: "port", label: "Port", valueType: "number", semantic: "port", section: "Connection"),
            TemplateField(key: "database", label: "Database", valueType: "text", semantic: "database", section: "Connection"),
        ]),
        CredentialType(id: "kafka", title: "Kafka", systemImage: "point.3.connected.trianglepath.dotted", itemType: "secret", fields: [
            TemplateField(key: "username", label: "Username", valueType: "text", semantic: "username", section: "Auth"),
            TemplateField(key: "brokers", label: "Brokers", valueType: "text", semantic: "brokers", section: "Connection"),
            TemplateField(key: "mechanism", label: "Mechanism", valueType: "text", semantic: "mechanism", section: "Auth"),
            TemplateField(key: "topic", label: "Topic", valueType: "text", semantic: "topic", section: "Connection"),
        ]),
        CredentialType(id: "custom", title: "New Type", systemImage: "plus.rectangle.on.folder.fill", itemType: "secret", fields: [
            TemplateField(key: "name", label: "Name", valueType: "text", semantic: "name", section: "Details"),
            TemplateField(key: "field_1", label: "Field 1", valueType: "text", semantic: nil, section: "Details"),
            TemplateField(key: "field_2", label: "Field 2", valueType: "text", semantic: nil, section: "Details"),
        ])
    ]

    static let browserFilters: [VaultBrowserFilter] = [
        VaultBrowserFilter(id: "all", title: "All Items", systemImage: "square.grid.2x2"),
        VaultBrowserFilter(id: "favorites", title: "Recent", systemImage: "clock"),
    ]

    @Published var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Self.serverURLKey) }
    }

    @Published var serverEnabled: Bool {
        didSet {
            defaults.set(serverEnabled, forKey: Self.serverEnabledKey)
            if serverEnabled {
                Task { await bootstrap() }
            } else {
                searchResults = localRecords
                selectedSearchRecord = localRecords.first
                latestSavedRecord = localRecords.first ?? latestSavedRecord
                statusMessage = "Local-only mode"
            }
        }
    }

    @Published var browserFilterID = "all"
    @Published var selectedTypeID = "s3"
    @Published var recordTitle = ""
    @Published var recordPassword = ""
    @Published var recordNote = ""
    @Published var recordUsername = ""
    @Published var pastedText = ""
    @Published var pastedTypeOverride = ""
    @Published var pastedTitleOverride = ""
    @Published var pastedNoteOverride = ""
    @Published var pastedFieldOverrides: [String: String] = [:]
    @Published var recordFields: [String: String] = [:]
    // Editor draft for the permission matrix; `aiAccess` here is the single
    // source of truth at save time (the legacy `recordAIReadable` boolean is
    // only a compatibility mirror on saved records).
    @Published var recordPermissions = RecordPermissions()
    // TOTP draft: empty input keeps the existing seed (never re-displayed),
    // a parseable input replaces it, and the remove flag clears it.
    @Published var recordTOTPInput = ""
    @Published private(set) var recordExistingTOTP: TOTPSecret?
    @Published var recordTOTPRemoveRequested = false
    @Published var latestSavedRecord: VaultRecord?
    // Menu bar quick access: transient copy feedback for the compact panel and
    // the most-recently-used record ids (ids only — never secret material).
    @Published private(set) var menuBarFeedback: String?
    @Published private(set) var recentQuickAccessIDs: [String] = []
    private var menuBarFeedbackDismissTask: Task<Void, Never>?

    @Published var searchQuery = ""
    @Published var searchResults: [VaultRecord] = []
    @Published var selectedSearchRecord: VaultRecord?
    @Published var searchFocusToken = 0
    @Published var selectedClusterBrowserID: String?
    @Published var clusterBrowserSortMode: ClusterBrowserSortMode = .count

    @Published var providerBaseURL = ""
    @Published var providerAPIKey = ""
    @Published var providerModel = "gpt-4o-mini"
    @Published var providerConfigured = false

    @Published var statusMessage = "Ready"
    @Published var isWorking = false
    @Published var isAuthenticated = true
    @Published var settingsPresented = false
    @Published var editorPresented = false
    @Published private(set) var localRecords: [VaultRecord] = []
    @Published private(set) var editingSignals: [VaultSignal] = []
    @Published private(set) var editingClusterID: String?
    @Published private(set) var editingClusterConfidence: Double?
    @Published private(set) var organizationSummary: OrganizationRunSummary?
    @Published var organizationIntervalDays: Double {
        didSet {
            let clamped = min(30, max(1, organizationIntervalDays))
            if clamped != organizationIntervalDays {
                organizationIntervalDays = clamped
                return
            }
            defaults.set(clamped, forKey: Self.organizationIntervalDaysKey)
        }
    }

    private(set) var editingRecordID: String?

    private static let serverURLKey = "SecretBox.serverURL"
    private static let serverEnabledKey = "SecretBox.serverEnabled"
    private static let localRecordsKey = "SecretBox.localRecords"
    private static let organizationLastRunKey = "SecretBox.organization.lastRun"
    private static let organizationThresholdBucketKey = "SecretBox.organization.thresholdBucket"
    private static let organizationSummaryKey = "SecretBox.organization.summary"
    private static let organizationIntervalDaysKey = "SecretBox.organization.intervalDays"
    private static let recentQuickAccessKey = "SecretBox.quickAccess.recent"
    private static let quickAccessResultLimit = 8
    private static let recentQuickAccessCapacity = 5
    private static let organizationThresholdStep = 20
    private let environment: [String: String]
    private let defaults: UserDefaults
    private let recordStore: RecordStoring
    private let reauthGate: any ReauthGate
    private let api = SecretBoxAPI()
    private var didAutoSaveUITestPastedText = false
    private var didPerformUITestSearch = false

    // Xcode 26 toolchains infer an isolated deinit for @MainActor classes; when the
    // last reference is released off the main actor the runtime hops executors and
    // hits a malloc abort (TaskLocal::StopLookupScope). Keep deinit nonisolated.
    nonisolated deinit {}

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         defaults: UserDefaults = .standard,
         recordStore: RecordStoring = KeychainRecordStore(),
         reauthGate: any ReauthGate = BiometricReauthGate()) {
        self.environment = environment
        self.defaults = defaults
        self.recordStore = recordStore
        self.reauthGate = reauthGate
        serverURL = defaults.string(forKey: Self.serverURLKey) ?? "http://127.0.0.1:8000"
        serverEnabled = defaults.object(forKey: Self.serverEnabledKey) as? Bool ?? false
        organizationIntervalDays = defaults.object(forKey: Self.organizationIntervalDaysKey) as? Double ?? 7
        if let data = defaults.data(forKey: Self.organizationSummaryKey) {
            organizationSummary = try? JSONDecoder().decode(OrganizationRunSummary.self, from: data)
        }
        recentQuickAccessIDs = defaults.stringArray(forKey: Self.recentQuickAccessKey) ?? []
        syncRecordFieldsWithSelectedType()
        loadLocalRecords()
        configureLaunchState()
    }

    func bootstrap() async {
        guard isAuthenticated else {
            statusMessage = "Please sign in"
            return
        }
        if shouldSkipServerCalls {
            searchResults = localRecords
            selectedSearchRecord = localRecords.first
            statusMessage = isUITesting ? "UI test mode" : "Offline mode"
            if !isUITesting {
                runAutomaticOrganizationIfNeeded(trigger: .periodic)
            }
            await performUITestAutoSaveIfNeeded()
            await performUITestSearchIfNeeded()
            performUITestPresentationHooksIfNeeded()
            return
        }
        await loadProviderSettings()
        await performUITestAutoSaveIfNeeded()
        await performUITestSearchIfNeeded()
        performUITestPresentationHooksIfNeeded()
    }

    func signIn(_ username: String, _ password: String) {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedUsername.isEmpty, !trimmedPassword.isEmpty else {
            statusMessage = "Enter username and password"
            return
        }

        isAuthenticated = true
        statusMessage = "Signed in as \(trimmedUsername)"
        Task {
            await bootstrap()
        }
    }

    func setAuthenticated(_ authenticated: Bool) {
        isAuthenticated = authenticated
        if authenticated {
            Task {
                await bootstrap()
            }
        } else {
            statusMessage = "Signed out"
        }
    }

    var selectedType: CredentialType {
        Self.supportedTypes.first(where: { $0.id == selectedTypeID }) ?? Self.supportedTypes[0]
    }

    var isEditingRecord: Bool {
        editingRecordID != nil
    }

    /// True while the editor is open on a read-only record. Flipping the
    /// read-only toggle off in the editor is the deliberate unlock path, so
    /// `saveRecord` re-checks the *draft* matrix before enforcing the lock.
    var editingRecordIsLocked: Bool {
        guard let editingRecordID else { return false }
        return localRecords.first(where: { $0.id == editingRecordID })?.effectivePermissions.readOnly ?? false
    }

    var filteredResults: [VaultRecord] {
        let base = searchResults.isEmpty ? (localRecords.isEmpty ? (latestSavedRecord.map { [$0] } ?? []) : localRecords) : searchResults
        let clusterScoped = if let selectedClusterBrowserID {
            sortRecordsWithinCluster(base.filter { ($0.clusterLabel ?? "") == selectedClusterBrowserID })
        } else {
            base
        }
        switch browserFilterID {
        case "all":
            return clusterScoped
        case "favorites":
            return Array(clusterScoped.prefix(6))
        default:
            return clusterScoped.filter { $0.recordType == browserFilterID }
        }
    }

    var displayedTags: [String] {
        let hiddenTags = Set(Self.supportedTypes.map(\.id) + ["local"])
        return (selectedSearchRecord?.tags ?? latestSavedRecord?.tags ?? []).filter { !hiddenTags.contains($0) }
    }

    var selectedBrowserFilter: VaultBrowserFilter {
        Self.browserFilters.first(where: { $0.id == browserFilterID }) ?? Self.browserFilters[0]
    }

    var browserTitle: String {
        if let selectedClusterBrowserID {
            return selectedClusterBrowserID
        }
        return selectedBrowserFilter.title
    }

    var browserSubtitle: String {
        "\(filteredResults.count) item\(filteredResults.count == 1 ? "" : "s")"
    }

    var clusterBrowserSummaries: [ClusterBrowserSummary] {
        let source = localRecords.isEmpty ? searchResults : localRecords
        let grouped = Dictionary(grouping: source) { record in
            record.clusterLabel ?? "Unorganized"
        }

        return grouped.compactMap { label, records in
            guard !records.isEmpty else { return nil }
            let representative = records[0]
            let recencyRank = source.firstIndex(where: { ($0.clusterLabel ?? "Unorganized") == label }) ?? Int.max
            let highlights = representative.clusterSchemaDefinition.fields.compactMap { field in
                if let value = clusterPreferredValue(for: representative, names: field.keys), !value.isEmpty {
                    return "\(field.label): \(value)"
                }
                return nil
            }
            return ClusterBrowserSummary(
                id: label,
                label: label,
                title: representative.clusterSchemaDefinition.title,
                count: records.count,
                highlights: Array(highlights.prefix(2)),
                latestActivityAt: records.compactMap(\.lastOrganizedAt).max(),
                recencyRank: recencyRank
            )
        }
        .sorted { lhs, rhs in
            switch clusterBrowserSortMode {
            case .count:
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            case .recent:
                let lhsDate = lhs.latestActivityAt ?? .distantPast
                let rhsDate = rhs.latestActivityAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                if lhs.recencyRank != rhs.recencyRank { return lhs.recencyRank < rhs.recencyRank }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            case .name:
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
        }
    }

    var pastedSecretPreview: PastedSecretPreview? {
        let normalized = normalizeUnstructuredInput(pastedText)
        guard !normalized.isEmpty else { return nil }
        // Mirror the save path: a Key URI in the paste is routed to the
        // dedicated TOTP channel, never into the parsed fields.
        let capturedTOTP = extractPastedTOTP(from: normalized)
        let parseableText = capturedTOTP?.remainder ?? normalized
        if parseableText.isEmpty, let totp = capturedTOTP?.totp {
            return PastedSecretPreview(
                templateType: "account",
                clusterDecision: parsedAccountClusterDecision,
                signals: [],
                tags: ["totp", "两步验证"],
                highlights: ["Authenticator: \(totp.issuer ?? totp.account ?? "未命名")"],
                hasSecret: false,
                editableFields: [],
                hasTOTP: true
            )
        }
        let parsed = parseLocalPastedSecret(parseableText)
        let effectiveType = pastedTypeOverride.isEmpty ? parsed.templateType : pastedTypeOverride
        let fields = applyPastedFieldOverrides(to: parsed.fields)
        let highlights = fields
            .filter { $0.key != "source_excerpt" }
            .prefix(4)
            .map { "\($0.label): \($0.value)" }
        var previewTags = previewTags(from: parsed.signals, fields: fields, secret: parsed.primarySecret, templateType: effectiveType)
        if capturedTOTP != nil {
            previewTags.append("两步验证")
        }
        return PastedSecretPreview(
            templateType: effectiveType,
            clusterDecision: parsed.clusterDecision,
            signals: parsed.signals,
            tags: previewTags,
            highlights: Array(highlights),
            hasSecret: parsed.primarySecret != nil,
            editableFields: fields
                .filter { !$0.hidden && $0.key != "source_excerpt" && !$0.value.isEmpty }
                .prefix(5)
                .map { PastedPreviewField(key: $0.key, label: $0.label, value: $0.value) },
            hasTOTP: capturedTOTP != nil
        )
    }

    private var parsedAccountClusterDecision: ClusterDecision {
        ClusterDecision(
            clusterID: .humanAccountLogin,
            confidence: 1,
            reasons: ["otpauth URI"]
        )
    }

    var suggestedFieldGroups: [(title: String, keys: [String])] {
        let grouped = Dictionary(grouping: selectedType.fields) { $0.section }
        return grouped.keys.sorted().map { title in
            (title, grouped[title, default: []].map(\.key))
        }
    }

    var editingFieldGroups: [(title: String, keys: [String])] {
        let signalOrderedKeys = prioritizedEditingSignalKeys.filter { key in
            let value = recordFields[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty
        }

        let remainingKeys = recordFields.keys
            .filter { key in
                !prioritizedEditingSignalKeys.contains(key)
                    && key != "username"
                    && key != "source_excerpt"
                    && !(recordFields[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .sorted()

        var groups: [(title: String, keys: [String])] = []
        if !signalOrderedKeys.isEmpty {
            groups.append(("Detected Context", signalOrderedKeys))
        }
        if !remainingKeys.isEmpty {
            groups.append(("Structured Fields", remainingKeys))
        }
        if groups.isEmpty {
            groups = suggestedFieldGroups
        }
        return groups
    }

    var editingClusterSummary: String? {
        guard let editingClusterID else { return nil }
        let title = editingClusterID
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
        if let editingClusterConfidence {
            return "\(title) · \(Int(editingClusterConfidence * 100))%"
        }
        return title
    }

    func selectBrowserFilter(_ filterID: String) {
        browserFilterID = filterID
    }

    func browseCluster(_ clusterID: String?) {
        selectedClusterBrowserID = clusterID
        if let clusterID {
            let scoped = filteredResults.filter { ($0.clusterLabel ?? "") == clusterID }
            selectedSearchRecord = scoped.first ?? filteredResults.first
        }
    }

    func selectType(_ typeID: String) {
        selectedTypeID = typeID
        syncRecordFieldsWithSelectedType()
    }

    func beginCreate() {
        editingRecordID = nil
        resetEditorDraft()
        editorPresented = true
    }

    func beginEditing(_ record: VaultRecord) {
        editingRecordID = record.id
        populateDraft(from: record)
        editorPresented = true
    }

    func dismissEditor() {
        // Close the keyboard first: on iOS a still-attached keyboard can
        // make the programmatic sheet dismissal silently no-op.
        PlatformKeyboard.resignActiveResponder()
        editorPresented = false
    }

    func syncRecordFieldsWithSelectedType() {
        let template = selectedType.fields
        var next = template.reduce(into: [String: String]()) { partialResult, field in
            partialResult[field.key] = recordFields[field.key] ?? ""
        }
        for (key, value) in recordFields where next[key] == nil {
            next[key] = value
        }
        recordFields = next
        if recordTitle.isEmpty {
            recordTitle = selectedType.title
        }
    }

    func loadProviderSettings() async {
        do {
            let settings = try await api.fetchProviderSettings(baseURL: serverURL)
            providerConfigured = settings.configured
            providerBaseURL = settings.baseURL ?? providerBaseURL
            providerModel = settings.model ?? providerModel
            statusMessage = settings.configured ? "AI provider configured" : "AI provider not configured"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func saveProviderSettings() async {
        if shouldSkipServerCalls {
            providerConfigured = true
            providerAPIKey = ""
            statusMessage = "Provider settings saved"
            return
        }
        isWorking = true
        defer { isWorking = false }

        do {
            let payload = ProviderSettingsPayload(baseURL: providerBaseURL, apiKey: providerAPIKey, model: providerModel)
            let settings = try await api.saveProviderSettings(baseURL: serverURL, payload: payload)
            providerConfigured = settings.configured
            providerAPIKey = ""
            statusMessage = "Provider settings saved"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func saveRecord() async {
        guard !recordPassword.isEmpty else {
            statusMessage = "Password is required"
            return
        }
        if let editingRecordID,
           let existing = localRecords.first(where: { $0.id == editingRecordID }),
           existing.effectivePermissions.readOnly,
           recordPermissions.readOnly {
            statusMessage = "Record is locked read-only"
            return
        }

        let resolvedTOTP: TOTPSecret?
        let removesTOTP: Bool
        if recordTOTPRemoveRequested {
            resolvedTOTP = nil
            removesTOTP = true
        } else {
            let trimmedTOTP = recordTOTPInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedTOTP.isEmpty {
                resolvedTOTP = recordExistingTOTP
                removesTOTP = false
            } else if let parsed = TOTPSecret.fromUserInput(trimmedTOTP) {
                resolvedTOTP = parsed
                removesTOTP = false
            } else {
                statusMessage = "TOTP seed must be a base32 secret or otpauth:// URI"
                return
            }
        }

        let draftClassification = classifyEditorDraft()

        let payload = VaultItemCreateRequest(
            itemType: draftClassification.itemType,
            templateType: draftClassification.templateType,
            name: recordTitle.isEmpty ? draftClassification.defaultName : recordTitle,
            pastedText: pastedText,
            primarySecret: recordPassword,
            notes: recordNote,
            tags: draftClassification.tags,
            fields: makeVaultFields(),
            totp: resolvedTOTP,
            removeTOTP: removesTOTP ? true : nil,
            permissions: recordPermissions
        )

        if shouldSkipServerCalls {
            let record = VaultRecord(
                id: editingRecordID ?? UUID().uuidString,
                itemType: payload.itemType,
                templateType: payload.templateType,
                clusterID: draftClassification.clusterDecision.clusterID.rawValue,
                clusterConfidence: draftClassification.clusterDecision.confidence,
                signals: draftClassification.signals,
                clusterLabel: suggestedClusterLabel(for: draftClassification.clusterDecision, signals: draftClassification.signals, templateType: payload.templateType ?? draftClassification.templateType),
                name: payload.name,
                subtitle: recordUsername.isEmpty ? nil : recordUsername,
                notes: recordNote.isEmpty ? draftClassification.defaultNotes : recordNote,
                tags: payload.tags + ["local"],
                fields: payload.fields,
                passwordHash: "local-hash",
                passwordFingerprint: "local-fingerprint",
                primarySecret: recordPassword,
                matchReason: isEditingRecord ? "updated locally for testing" : "saved locally for testing",
                aiReadable: recordPermissions.aiAccess != .none,
                totp: resolvedTOTP,
                permissions: recordPermissions
            )
            upsertLocalRecord(record)
            runAutomaticOrganizationIfNeeded(trigger: .threshold)
            selectedTypeID = draftClassification.templateType
            editingSignals = draftClassification.signals
            editingClusterID = draftClassification.clusterDecision.clusterID.rawValue
            editingClusterConfidence = draftClassification.clusterDecision.confidence
            statusMessage = isEditingRecord ? "Updated \(record.description)" : "Saved \(record.description)"
            editingRecordID = nil
            editingSignals = []
            editingClusterID = nil
            editingClusterConfidence = nil
            dismissEditor()
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let record: VaultRecord
            if let editingRecordID {
                record = try await api.updateRecord(baseURL: serverURL, recordID: editingRecordID, payload: payload)
            } else {
                record = try await api.saveRecord(baseURL: serverURL, payload: payload)
            }
            upsertLocalRecord(record)
            selectedTypeID = record.templateType ?? draftClassification.templateType
            statusMessage = isEditingRecord ? "Updated \(record.description)" : "Saved \(record.description)"
            self.editingRecordID = nil
            editingSignals = []
            editingClusterID = nil
            editingClusterConfidence = nil
            dismissEditor()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func pasteClipboardAndSave() async {
        let clipboard = PlatformClipboard.string ?? ""
        guard !clipboard.isEmpty else {
            statusMessage = "Clipboard is empty"
            return
        }
        recordPassword = clipboard
        pastedText = clipboard
        await saveRecord()
    }

    func saveFromPastedText() async {
        let normalized = normalizeUnstructuredInput(pastedText)
        guard !normalized.isEmpty else {
            statusMessage = "Paste content first"
            return
        }

        // Pull a Key URI out of the paste before template parsing so the seed
        // rides the dedicated `totp` channel instead of leaking into fields.
        let capturedTOTP = extractPastedTOTP(from: normalized)
        let parseableText = capturedTOTP?.remainder ?? normalized

        if shouldSkipServerCalls {
            if parseableText.isEmpty, let totp = capturedTOTP?.totp {
                // URI-only paste: a bare authenticator entry carrying the seed.
                let name = totp.issuer ?? totp.account ?? "Authenticator"
                let record = VaultRecord(
                    id: UUID().uuidString,
                    itemType: "login",
                    templateType: "account",
                    clusterID: CredentialClusterID.humanAccountLogin.rawValue,
                    clusterConfidence: 1,
                    signals: [],
                    clusterLabel: nil,
                    name: name,
                    subtitle: totp.account,
                    notes: "Captured from an otpauth:// URI",
                    tags: ["account", "local"],
                    fields: [],
                    passwordHash: "local-hash",
                    passwordFingerprint: "local-fingerprint",
                    primarySecret: nil,
                    matchReason: "saved locally from pasted TOTP URI",
                    aiReadable: recordPermissions.aiAccess != .none,
                    totp: totp,
                    permissions: recordPermissions
                )
                upsertLocalRecord(record)
                runAutomaticOrganizationIfNeeded(trigger: .threshold)
                statusMessage = "Saved authenticator item"
                showMenuBarFeedback("Saved · \(record.name)")
                resetPastedCaptureState()
                dismissEditor()
                return
            }

            let parsed = parseLocalPastedSecret(parseableText)
            let effectiveType = pastedTypeOverride.isEmpty ? parsed.templateType : pastedTypeOverride
            let effectiveTitle = pastedTitleOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveNote = pastedNoteOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveFields = applyPastedFieldOverrides(to: parsed.fields)
            let record = VaultRecord(
                id: UUID().uuidString,
                itemType: effectiveType == "account" ? "login" : "secret",
                templateType: effectiveType,
                clusterID: parsed.clusterDecision.clusterID.rawValue,
                clusterConfidence: parsed.clusterDecision.confidence,
                signals: parsed.signals,
                clusterLabel: suggestedClusterLabel(for: parsed.clusterDecision, signals: parsed.signals, templateType: effectiveType),
                name: effectiveTitle.isEmpty ? parsed.name : effectiveTitle,
                subtitle: nil,
                notes: effectiveNote.isEmpty ? parsed.notes : effectiveNote,
                tags: Array(Set(parsed.tags + [effectiveType])),
                fields: effectiveFields,
                passwordHash: "local-hash",
                passwordFingerprint: "local-fingerprint",
                primarySecret: parsed.primarySecret,
                matchReason: "saved locally from pasted text",
                aiReadable: recordPermissions.aiAccess != .none,
                totp: capturedTOTP?.totp,
                permissions: recordPermissions
            )
            upsertLocalRecord(record)
            runAutomaticOrganizationIfNeeded(trigger: .threshold)
            statusMessage = "Saved captured item"
            showMenuBarFeedback("Saved · \(record.name)")
            resetPastedCaptureState()
            dismissEditor()
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let record = try await api.saveRecord(
                baseURL: serverURL,
                payload: VaultItemCreateRequest(
                    itemType: "secret",
                    templateType: nil,
                    name: "",
                    pastedText: parseableText.isEmpty ? normalized : parseableText,
                    primarySecret: nil,
                    notes: "",
                    tags: [],
                    fields: [],
                    totp: capturedTOTP?.totp,
                    permissions: recordPermissions.aiAccess == .none ? nil : recordPermissions
                )
            )
            upsertLocalRecord(record)
            selectedTypeID = record.templateType ?? selectedTypeID
            statusMessage = "Saved \(record.title)"
            showMenuBarFeedback("Saved · \(record.title)")
            resetPastedCaptureState()
            recordPassword = ""
            dismissEditor()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Extracts an `otpauth://totp/...` Key URI from pasted text, returning
    /// the parsed seed plus the text with the URI removed. Returns nil when
    /// no parseable URI is present (a malformed URI stays in the text and is
    /// handled as ordinary content).
    private func extractPastedTOTP(from text: String) -> (totp: TOTPSecret, remainder: String)? {
        guard let prefixRange = text.range(of: "otpauth://", options: .caseInsensitive) else { return nil }
        let afterPrefix = text[prefixRange.upperBound...]
        let uriEnd = afterPrefix.firstIndex(where: \.isWhitespace) ?? afterPrefix.endIndex
        let uri = "otpauth://" + afterPrefix[afterPrefix.startIndex..<uriEnd]
        guard let secret = TOTPEngine.parseOTPAuthURI(uri) else { return nil }
        let remainder = (String(text[..<prefixRange.lowerBound]) + String(afterPrefix[uriEnd...]))
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (secret, remainder)
    }

    private func resetPastedCaptureState() {
        pastedText = ""
        pastedTypeOverride = ""
        pastedTitleOverride = ""
        pastedNoteOverride = ""
        pastedFieldOverrides = [:]
    }

    func searchPasswords() async {
        guard !searchQuery.isEmpty else {
            statusMessage = "Enter a query"
            return
        }

        if shouldSkipServerCalls {
            let source = localRecords.isEmpty ? seededRecords : localRecords
            let results = rankedLocalResults(for: searchQuery, source: source)
            searchResults = results
            selectedSearchRecord = results.first
            statusMessage = "Found \(results.count) result(s)"
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let response = try await api.search(
                baseURL: serverURL,
                payload: PasswordSearchRequest(query: searchQuery, limit: 6)
            )
            searchResults = response.results
            selectedSearchRecord = response.results.first
            statusMessage = "Found \(response.results.count) result(s)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteRecord(id: String) {
        if let record = localRecords.first(where: { $0.id == id }), record.effectivePermissions.readOnly {
            statusMessage = "Record is locked read-only"
            return
        }
        guard let index = localRecords.firstIndex(where: { $0.id == id }) else {
            searchResults.removeAll { $0.id == id }
            if selectedSearchRecord?.id == id {
                selectedSearchRecord = nil
            }
            return
        }

        let name = localRecords[index].name
        localRecords.remove(at: index)
        persistLocalRecords()
        searchResults.removeAll { $0.id == id }
        if selectedSearchRecord?.id == id {
            selectedSearchRecord = searchResults.first ?? localRecords.first
        }
        if latestSavedRecord?.id == id {
            latestSavedRecord = localRecords.first
        }
        if editingRecordID == id {
            dismissEditor()
        }
        statusMessage = "Deleted \(name)"
    }

    /// Set the AI agent access level for a record (MCP). Persists immediately.
    func setAIAccess(id: String, level: AIAccessLevel) {
        guard let index = localRecords.firstIndex(where: { $0.id == id }) else { return }
        var permissions = localRecords[index].effectivePermissions
        permissions.aiAccess = level
        localRecords[index].permissions = permissions
        // Legacy boolean mirror so pre-matrix MCP builds keep reading the
        // opt-in correctly; `false` (not nil) stays the explicit disabled state.
        localRecords[index].aiReadable = level != .none
        persistLocalRecords()

        if let updated = localRecords.first(where: { $0.id == id }) {
            if let resultIndex = searchResults.firstIndex(where: { $0.id == id }) {
                searchResults[resultIndex] = updated
            }
            if selectedSearchRecord?.id == id {
                selectedSearchRecord = updated
            }
            if latestSavedRecord?.id == id {
                latestSavedRecord = updated
            }
        }
        let name = localRecords.first(where: { $0.id == id })?.name ?? id
        switch level {
        case .none:
            statusMessage = "AI access disabled for \(name)"
        case .metadata:
            statusMessage = "AI metadata access enabled for \(name)"
        case .metadataAndTools:
            statusMessage = "AI access enabled for \(name)"
        }
    }

    /// Legacy boolean entry point — "allowed" maps onto the leveled model as
    /// full tool access, matching what a pre-matrix opt-in meant.
    func setAIReadable(id: String, allowed: Bool) {
        setAIAccess(id: id, level: allowed ? .metadataAndTools : .none)
    }

    func copyPassword(_ password: String) {
        PlatformClipboard.copy(password)
        statusMessage = "Password copied"
    }

    func copyTOTPCode(_ code: String) {
        PlatformClipboard.copy(code)
        statusMessage = "Verification code copied"
    }

    /// Re-prompt gate for records carrying the requireReauth permission
    /// (Bitwarden's master password re-prompt equivalent). Returns false when
    /// authentication failed or no biometrics/passcode are enrolled — callers
    /// must abort the secret operation, never fall through.
    func requestSecretUse(for record: VaultRecord, action: String) async -> Bool {
        guard record.effectivePermissions.requireReauth else { return true }
        let granted = await reauthGate.authenticate(reason: "Authenticate to \(action)")
        if !granted {
            statusMessage = "Authentication required to \(action)"
        }
        return granted
    }

    /// Copies the redacted `<secretbox-credential>` reference for a record so
    /// the user can paste it into an AI agent chat in place of the plaintext.
    /// Callers must gate on `aiReadable` — a reference for a record the agent
    /// cannot see would be unresolvable.
    func copyAIReference(for record: VaultRecord) {
        PlatformClipboard.copy(record.aiAgentReference)
        statusMessage = "AI reference copied for \(record.name)"
    }

    // MARK: - Menu bar quick access

    /// Ranked results for the menu bar search field — the same local scorer as
    /// the main-window search (title/tags/fields/signals), capped for the
    /// compact panel. An empty query returns nothing; the panel shows the
    /// recent list instead.
    func quickAccessResults(for query: String) -> [VaultRecord] {
        Array(rankedLocalResults(for: query, source: quickAccessSource).prefix(Self.quickAccessResultLimit))
    }

    /// Recently used records, most recent first. Stale ids (records deleted or
    /// not yet loaded) drop out silently.
    var recentQuickAccessRecords: [VaultRecord] {
        let available = quickAccessSource
        return recentQuickAccessIDs.compactMap { id in available.first(where: { $0.id == id }) }
    }

    /// Menu-bar save enablement: a capture is savable when a secret or a Key
    /// URI was detected (a URI-only paste still creates an authenticator item).
    var canSavePastedCapture: Bool {
        guard let preview = pastedSecretPreview else { return false }
        return preview.hasSecret || preview.hasTOTP
    }

    /// Same source as the main-window local search: the user's records, with
    /// the demo seeds only when the vault is completely empty.
    private var quickAccessSource: [VaultRecord] {
        localRecords.isEmpty ? seededRecords : localRecords
    }

    /// Remembers a quick-access use, most recent first and capped. Ids only —
    /// the same non-secret standing as the other UserDefaults preferences.
    private func noteQuickAccess(_ id: String) {
        var ids = recentQuickAccessIDs.filter { $0 != id }
        ids.insert(id, at: 0)
        if ids.count > Self.recentQuickAccessCapacity {
            ids = Array(ids.prefix(Self.recentQuickAccessCapacity))
        }
        recentQuickAccessIDs = ids
        defaults.set(ids, forKey: Self.recentQuickAccessKey)
    }

    private func showMenuBarFeedback(_ message: String) {
        menuBarFeedback = message
        menuBarFeedbackDismissTask?.cancel()
        menuBarFeedbackDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.menuBarFeedback = nil
        }
    }

    func quickAccessCopyPassword(for record: VaultRecord) async {
        guard let password = record.password, !password.isEmpty else {
            showMenuBarFeedback("No password stored · \(record.title)")
            return
        }
        guard await requestSecretUse(for: record, action: "copy the password") else { return }
        copyPassword(password)
        noteQuickAccess(record.id)
        showMenuBarFeedback("Password copied · \(record.title)")
    }

    func quickAccessCopyTOTP(for record: VaultRecord) async {
        guard let totp = record.totp else {
            showMenuBarFeedback("No verification code · \(record.title)")
            return
        }
        guard await requestSecretUse(for: record, action: "copy the verification code") else { return }
        guard let code = TOTPEngine.code(for: totp, at: Date()) else {
            showMenuBarFeedback("Cannot generate code · \(record.title)")
            return
        }
        copyTOTPCode(code)
        noteQuickAccess(record.id)
        showMenuBarFeedback("Verification code copied · \(record.title)")
    }

    /// The reference is only offered for records the agent can actually see;
    /// for `aiAccess == .none` it would be unresolvable, so the call is a no-op.
    func quickAccessCopyAIReference(for record: VaultRecord) {
        guard record.effectivePermissions.aiAccess != .none else { return }
        copyAIReference(for: record)
        noteQuickAccess(record.id)
        showMenuBarFeedback("AI reference copied · \(record.title)")
    }

    func updateField(_ key: String, value: String) {
        recordFields[key] = value
    }

    func humanizedFieldName(_ key: String) -> String {
        key
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    func openSearchFromMenuBar() {
        browserFilterID = "all"
        selectedClusterBrowserID = nil
        if let latestSavedRecord {
            if localRecords.contains(where: { $0.id == latestSavedRecord.id }) {
                searchResults = localRecords
            }
            selectedSearchRecord = latestSavedRecord
        } else if let firstLocalRecord = localRecords.first {
            searchResults = localRecords
            selectedSearchRecord = firstLocalRecord
            latestSavedRecord = firstLocalRecord
        }
        searchFocusToken += 1
    }

    /// Focuses one specific record in the main window (menu bar ⌘↩ / row
    /// action). Mirrors `openSearchFromMenuBar` but for an explicit target.
    func revealRecordInDashboard(_ record: VaultRecord) {
        browserFilterID = "all"
        selectedClusterBrowserID = nil
        if localRecords.contains(where: { $0.id == record.id }) {
            searchResults = localRecords
        }
        selectedSearchRecord = record
        searchFocusToken += 1
    }

    var organizationSummaryText: String {
        guard let organizationSummary else {
            return "Initial template classification runs on save. Custom items are reclustered after 20 unmatched captures and every \(Int(organizationIntervalDays)) day(s)."
        }
        return "Last run: \(organizationSummary.processedRecords) items, \(organizationSummary.customRecords) custom, \(organizationSummary.generatedClusters) clusters, \(organizationSummary.promotedRecords) promoted. Periodic review: every \(Int(organizationIntervalDays)) day(s)."
    }

    func runSmartOrganizationNow() async {
        isWorking = true
        defer { isWorking = false }
        let summary = runOrganizationPass(trigger: .manual)
        statusMessage = "Organized \(summary.processedRecords) item(s)"
    }

    private var isUITesting: Bool {
        environment["SECRETBOX_UI_TEST"] == "1"
    }

    private var shouldSkipServerCalls: Bool {
        environment["SECRETBOX_SKIP_NETWORK"] == "1" || isUITesting || !serverEnabled
    }

    private var seededRecords: [VaultRecord] {
        [
            VaultRecord(
                id: "seed-s3",
                itemType: "secret",
                templateType: "s3",
                name: "Prod S3 Bucket",
                subtitle: "ops-bot",
                notes: "Production S3 access key for artifact bucket",
                tags: ["s3", "prod", "artifact"],
                fields: [
                    VaultField(key: "username", label: "Username", value: "ops-bot", valueType: "text", semantic: "username", hidden: false, section: "Auth", order: 0),
                    VaultField(key: "endpoint", label: "Endpoint", value: "s3.internal.example.com", valueType: "url", semantic: "endpoint", hidden: false, section: "Connection", order: 1),
                    VaultField(key: "bucket", label: "Bucket", value: "artifacts-prod", valueType: "text", semantic: "bucket", hidden: false, section: "Connection", order: 2),
                    VaultField(key: "access_key", label: "Access Key", value: "ops-artifact-ak", valueType: "text", semantic: "access_key", hidden: false, section: "Auth", order: 3),
                    VaultField(key: "region", label: "Region", value: "ap-east-1", valueType: "text", semantic: "region", hidden: false, section: "Connection", order: 4),
                ],
                passwordHash: "seed-hash-1",
                passwordFingerprint: "seed-fingerprint-1",
                primarySecret: "seed-secret-s3",
                matchReason: "seed data"
            ),
            VaultRecord(
                id: "seed-db",
                itemType: "secret",
                templateType: "database",
                name: "Billing Postgres",
                subtitle: "billing_admin",
                notes: "Primary postgres password for billing database",
                tags: ["database", "postgres", "billing"],
                fields: [
                    VaultField(key: "username", label: "Username", value: "billing_admin", valueType: "text", semantic: "username", hidden: false, section: "Auth", order: 0),
                    VaultField(key: "engine", label: "Engine", value: "postgres", valueType: "text", semantic: "engine", hidden: false, section: "Connection", order: 1),
                    VaultField(key: "host", label: "Host", value: "billing-db.internal", valueType: "text", semantic: "host", hidden: false, section: "Connection", order: 2),
                    VaultField(key: "port", label: "Port", value: "5432", valueType: "number", semantic: "port", hidden: false, section: "Connection", order: 3),
                    VaultField(key: "database", label: "Database", value: "billing", valueType: "text", semantic: "database", hidden: false, section: "Connection", order: 4),
                ],
                passwordHash: "seed-hash-2",
                passwordFingerprint: "seed-fingerprint-2",
                primarySecret: "seed-secret-db",
                matchReason: "seed data"
            ),
        ]
    }

    private func configureLaunchState() {
        guard isUITesting else {
            if !serverEnabled {
                searchResults = localRecords
                selectedSearchRecord = localRecords.first
                latestSavedRecord = localRecords.first
            }
            return
        }

        localRecords = []
        recordStore.clear()
        defaults.removeObject(forKey: Self.localRecordsKey)
        providerConfigured = true
        isAuthenticated = environment["SECRETBOX_UI_TEST_AUTH"] != "logged_out"
        searchResults = seededRecords
        selectedSearchRecord = seededRecords.first
        latestSavedRecord = seededRecords.first
        searchQuery = environment["SECRETBOX_UI_TEST_QUERY"] ?? ""
        pastedText = environment["SECRETBOX_UI_TEST_PASTED_TEXT"] ?? ""
        statusMessage = "UI test mode"
    }

    private func performUITestAutoSaveIfNeeded() async {
        guard isUITesting, !didAutoSaveUITestPastedText else { return }
        guard environment["SECRETBOX_UI_TEST_AUTO_SAVE_PASTED_TEXT"] == "1" else { return }
        guard let fixture = environment["SECRETBOX_UI_TEST_PASTED_TEXT"], !fixture.isEmpty else { return }
        didAutoSaveUITestPastedText = true
        pastedText = fixture
        await saveFromPastedText()
    }

    private func performUITestSearchIfNeeded() async {
        guard isUITesting, !didPerformUITestSearch else { return }
        let query = (environment["SECRETBOX_UI_TEST_QUERY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        didPerformUITestSearch = true
        searchQuery = query
        await searchPasswords()
    }

    /// Presentation hooks so documentation screenshots (and future UI tests)
    /// can reach specific surfaces purely via launch environment:
    /// `SECRETBOX_UI_TEST_CAPTURE_SHEET` / `_EDIT_SHEET` / `_SETTINGS_SHEET`.
    private func performUITestPresentationHooksIfNeeded() {
        guard isUITesting else { return }
        if environment["SECRETBOX_UI_TEST_CAPTURE_SHEET"] == "1" {
            beginCreate()
            if let preset = environment["SECRETBOX_UI_TEST_PASTED_TEXT"], !preset.isEmpty {
                pastedText = preset
            }
            return
        }
        if environment["SECRETBOX_UI_TEST_EDIT_SHEET"] == "1" {
            let target = localRecords.first(where: { $0.totp != nil }) ?? localRecords.first
            if let target { beginEditing(target) }
            return
        }
        if environment["SECRETBOX_UI_TEST_SETTINGS_SHEET"] == "1" {
            serverEnabled = true
            settingsPresented = true
        }
    }

    /// Editor scroll anchor for docs screenshots (e.g. "permissions"); nil
    /// outside UI-test mode.
    var uiTestEditorScrollAnchor: String? {
        guard isUITesting else { return nil }
        return environment["SECRETBOX_UI_TEST_EDITOR_SCROLL_TO"]
    }

    /// Menu-bar panel mode pin for UI tests and snapshot renders ("capture" /
    /// "search"); nil outside UI-test mode. Snapshot tests inject the
    /// environment here because the host process env stays unset.
    var uiTestMenuBarModePin: String? {
        guard isUITesting else { return nil }
        return environment["SECRETBOX_UI_TEST_MENU_BAR_MODE"]
    }

    var isUITestRun: Bool {
        isUITesting
    }

    private func resetEditorDraft() {
        if let defaultType = Self.supportedTypes.first {
            selectedTypeID = defaultType.id
        }
        recordTitle = ""
        recordPassword = ""
        recordNote = ""
        recordUsername = ""
        recordPermissions = RecordPermissions()
        recordTOTPInput = ""
        recordExistingTOTP = nil
        recordTOTPRemoveRequested = false
        pastedText = ""
        pastedTypeOverride = ""
        pastedTitleOverride = ""
        pastedNoteOverride = ""
        pastedFieldOverrides = [:]
        editingSignals = []
        editingClusterID = nil
        editingClusterConfidence = nil
        recordFields = [:]
        syncRecordFieldsWithSelectedType()
    }

    private func populateDraft(from record: VaultRecord) {
        selectedTypeID = record.templateType ?? selectedTypeID
        recordTitle = record.title
        recordPassword = record.password ?? ""
        recordNote = record.description
        recordUsername = record.username ?? ""
        recordPermissions = record.effectivePermissions
        // Never re-display the stored seed — an empty input means "keep".
        recordTOTPInput = ""
        recordExistingTOTP = record.totp
        recordTOTPRemoveRequested = false
        pastedText = ""
        pastedTypeOverride = ""
        pastedTitleOverride = ""
        pastedNoteOverride = ""
        pastedFieldOverrides = [:]
        editingSignals = record.signals ?? []
        editingClusterID = record.clusterID
        editingClusterConfidence = record.clusterConfidence
        recordFields = Dictionary(uniqueKeysWithValues: record.fields.map { ($0.key, $0.value) })
        syncRecordFieldsWithSelectedType()
    }

    private func classifyEditorDraft() -> (itemType: String, templateType: String, clusterDecision: ClusterDecision, signals: [VaultSignal], tags: [String], defaultName: String, defaultNotes: String) {
        let keyValues = editorDraftKeyValues()
        let synthesizedText = editorDraftText(from: keyValues)
        let primarySecret = recordPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : recordPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let signals = extractSignals(from: synthesizedText, keyValues: keyValues, secret: primarySecret)
        let clusterDecision = decideCluster(for: signals, text: synthesizedText, keyValues: keyValues)
        let templateType = deriveTemplateType(from: clusterDecision, text: synthesizedText, keyValues: keyValues)
        let fields = makeVaultFields()
        let redactedExcerpt = redactExcerpt(synthesizedText, secret: primarySecret)
        let defaultName = deriveRecordName(templateType: templateType, keyValues: keyValues, fields: fields)
        let defaultNotes = deriveNotes(templateType: templateType, keyValues: keyValues, redactedExcerpt: redactedExcerpt)
        let itemType = templateType == "account" ? "login" : "secret"
        let tags = [templateType]
        return (itemType, templateType, clusterDecision, signals, tags, defaultName, defaultNotes)
    }

    private func editorDraftKeyValues() -> [String: String] {
        var keyValues: [String: String] = [:]
        for (key, value) in recordFields {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                keyValues[key] = trimmed
            }
        }
        let username = recordUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if !username.isEmpty {
            keyValues["username"] = username
        }
        let title = recordTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            keyValues["label"] = keyValues["label"] ?? title
        }
        return keyValues
    }

    private func editorDraftText(from keyValues: [String: String]) -> String {
        let pairs = keyValues
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let note = recordNote.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([selectedTypeID] + pairs + (note.isEmpty ? [] : [note])).joined(separator: " ")
    }

    func bindingForPastedField(_ field: PastedPreviewField) -> Binding<String> {
        Binding(
            get: { [weak self] in
                guard let self else { return field.value }
                return self.pastedFieldOverrides[field.key] ?? field.value
            },
            set: { [weak self] newValue in
                self?.pastedFieldOverrides[field.key] = newValue
            }
        )
    }

    private func upsertLocalRecord(_ record: VaultRecord) {
        latestSavedRecord = record
        selectedSearchRecord = record
        if let localIndex = localRecords.firstIndex(where: { $0.id == record.id }) {
            localRecords[localIndex] = record
        } else {
            localRecords.insert(record, at: 0)
        }
        persistLocalRecords()
        if let existingIndex = searchResults.firstIndex(where: { $0.id == record.id }) {
            searchResults[existingIndex] = record
        } else {
            searchResults.insert(record, at: 0)
        }
    }

    private func loadLocalRecords() {
        let data = recordStore.loadData() ?? migrateLegacyLocalRecords()
        guard let data else {
            localRecords = []
            return
        }
        do {
            localRecords = try JSONDecoder().decode([VaultRecord].self, from: data)
        } catch {
            localRecords = []
        }
    }

    /// One-time migration from the legacy plaintext UserDefaults blob.
    private func migrateLegacyLocalRecords() -> Data? {
        guard let legacy = defaults.data(forKey: Self.localRecordsKey) else { return nil }
        recordStore.save(legacy)
        defaults.removeObject(forKey: Self.localRecordsKey)
        return legacy
    }

    private func persistLocalRecords() {
        do {
            let data = try JSONEncoder().encode(localRecords)
            recordStore.save(data)
        } catch {
            statusMessage = "Failed to persist local records"
        }
    }

    private func normalizeUnstructuredInput(_ text: String) -> String {
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

    private func runAutomaticOrganizationIfNeeded(trigger: OrganizationTrigger) {
        guard !isUITesting else { return }
        let customCount = unresolvedCustomRecords.count
        guard shouldRunAutomaticOrganization(trigger: trigger, customCount: customCount) else { return }
        _ = runOrganizationPass(trigger: trigger)
    }

    private func shouldRunAutomaticOrganization(trigger: OrganizationTrigger, customCount: Int) -> Bool {
        switch trigger {
        case .manual:
            return true
        case .periodic:
            guard customCount > 0 else { return false }
            guard let lastRun = defaults.object(forKey: Self.organizationLastRunKey) as? Date else { return true }
            return Date().timeIntervalSince(lastRun) >= organizationIntervalSeconds
        case .threshold:
            guard customCount > Self.organizationThresholdStep else { return false }
            return organizationThresholdBucket(for: customCount) > defaults.integer(forKey: Self.organizationThresholdBucketKey)
        }
    }

    private var organizationIntervalSeconds: TimeInterval {
        max(1, organizationIntervalDays) * 24 * 60 * 60
    }

    private var unresolvedCustomRecords: [VaultRecord] {
        localRecords.filter { ($0.templateType ?? $0.itemType) == "custom" }
    }

    private func organizationThresholdBucket(for customCount: Int) -> Int {
        guard customCount > Self.organizationThresholdStep else { return 0 }
        return (customCount - 1) / Self.organizationThresholdStep
    }

    @discardableResult
    private func runOrganizationPass(trigger: OrganizationTrigger) -> OrganizationRunSummary {
        let now = Date()
        let previousSelectionID = selectedSearchRecord?.id
        let previousLatestID = latestSavedRecord?.id
        var processed = localRecords.map(reclassifyLocalRecord)
        let customGroups = Dictionary(grouping: processed.enumerated().filter { ($0.element.templateType ?? $0.element.itemType) == "custom" }) { pair in
            customClusterSignature(for: pair.element)
        }

        var reclusteredRecords = 0
        var promotedRecords = 0
        var generatedClusters = 0

        for (_, entries) in customGroups.sorted(by: { $0.key < $1.key }) {
            guard !entries.isEmpty else { continue }
            let records = entries.map(\.element)
            let aggregate = aggregateOrganizationDecision(for: records)
            if entries.count > 1 {
                generatedClusters += 1
            }

            for entry in entries {
                let index = entry.offset
                let previousType = processed[index].templateType ?? processed[index].itemType
                processed[index].clusterID = aggregate.clusterDecision.clusterID.rawValue
                processed[index].clusterConfidence = max(processed[index].clusterConfidence ?? 0, aggregate.clusterDecision.confidence)
                processed[index].clusterLabel = aggregate.clusterLabel
                processed[index].lastOrganizedAt = now
                processed[index].tags = mergeRecordTags(
                    processed[index].tags,
                    templateType: previousType,
                    clusterLabel: aggregate.clusterLabel
                )

                if previousType == "custom", aggregate.templateType != "custom", aggregate.clusterDecision.confidence >= 0.55 {
                    processed[index].templateType = aggregate.templateType
                    processed[index].itemType = aggregate.templateType == "account" ? "login" : "secret"
                    promotedRecords += 1
                }
                reclusteredRecords += 1
            }
        }

        localRecords = processed
        persistLocalRecords()

        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchResults = localRecords
        } else {
            searchResults = rankedLocalResults(for: searchQuery, source: localRecords)
        }
        if let previousSelectionID, let refreshedSelection = localRecords.first(where: { $0.id == previousSelectionID }) {
            selectedSearchRecord = refreshedSelection
        } else {
            selectedSearchRecord = searchResults.first
        }
        if let previousLatestID, let refreshedLatest = localRecords.first(where: { $0.id == previousLatestID }) {
            latestSavedRecord = refreshedLatest
        } else {
            latestSavedRecord = localRecords.first
        }

        let summary = OrganizationRunSummary(
            trigger: trigger.rawValue,
            processedRecords: processed.count,
            customRecords: processed.filter { ($0.templateType ?? $0.itemType) == "custom" }.count,
            reclusteredRecords: reclusteredRecords,
            promotedRecords: promotedRecords,
            generatedClusters: generatedClusters,
            ranAt: now
        )

        organizationSummary = summary
        defaults.set(now, forKey: Self.organizationLastRunKey)
        defaults.set(organizationThresholdBucket(for: summary.customRecords), forKey: Self.organizationThresholdBucketKey)
        if let data = try? JSONEncoder().encode(summary) {
            defaults.set(data, forKey: Self.organizationSummaryKey)
        }
        return summary
    }

    private func reclassifyLocalRecord(_ record: VaultRecord) -> VaultRecord {
        let keyValues = record.fieldMap.reduce(into: [String: String]()) { partialResult, pair in
            let trimmed = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                partialResult[pair.key] = trimmed
            }
        }
        let synthesizedText = normalizeUnstructuredInput(organizationSourceText(for: record, keyValues: keyValues))
        let secret = record.primarySecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        let signals = extractSignals(from: synthesizedText, keyValues: keyValues, secret: secret)
        let clusterDecision = decideCluster(for: signals, text: synthesizedText, keyValues: keyValues)
        let derivedTemplateType = deriveTemplateType(from: clusterDecision, text: synthesizedText, keyValues: keyValues)

        var next = record
        next.signals = signals
        next.clusterID = clusterDecision.clusterID.rawValue
        next.clusterConfidence = clusterDecision.confidence
        next.clusterLabel = suggestedClusterLabel(for: clusterDecision, signals: signals, templateType: derivedTemplateType)
        next.lastOrganizedAt = Date()

        if (next.templateType ?? next.itemType) == "custom", derivedTemplateType != "custom", clusterDecision.confidence >= 0.55 {
            next.templateType = derivedTemplateType
            next.itemType = derivedTemplateType == "account" ? "login" : "secret"
        }

        next.tags = mergeRecordTags(next.tags, templateType: next.templateType ?? next.itemType, clusterLabel: next.clusterLabel)
        return next
    }

    private func organizationSourceText(for record: VaultRecord, keyValues: [String: String]) -> String {
        var components: [String] = []
        if !record.title.isEmpty {
            components.append(record.title)
        }
        if !record.notes.isEmpty {
            components.append(record.notes)
        }
        components.append(contentsOf: keyValues.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" })
        if let secret = record.primarySecret, !secret.isEmpty {
            components.append("password=\(secret)")
        }
        return components.joined(separator: " ")
    }

    private func aggregateOrganizationDecision(for records: [VaultRecord]) -> (clusterDecision: ClusterDecision, templateType: String, clusterLabel: String) {
        let mergedSignals = deduplicateSignals(records.flatMap { $0.signals ?? [] })
        let mergedKeyValues = records.reduce(into: [String: String]()) { partialResult, record in
            for field in record.fields where partialResult[field.key] == nil && !field.value.isEmpty {
                partialResult[field.key] = field.value
            }
        }
        let mergedText = records
            .map { normalizeUnstructuredInput(organizationSourceText(for: $0, keyValues: $0.fieldMap)) }
            .joined(separator: " ")
        let clusterDecision = decideCluster(for: mergedSignals, text: mergedText, keyValues: mergedKeyValues)
        let templateType = deriveTemplateType(from: clusterDecision, text: mergedText, keyValues: mergedKeyValues)
        let clusterLabel = suggestedClusterLabel(for: clusterDecision, signals: mergedSignals, templateType: templateType)
        return (clusterDecision, templateType, clusterLabel)
    }

    private func customClusterSignature(for record: VaultRecord) -> String {
        let signals = record.signals ?? []
        if signals.isEmpty {
            return "freeform"
        }
        let keyPriority = [
            "endpoint", "url", "host", "brokers",
            "database", "bucket", "topic", "vhost", "scope", "project",
            "service", "label", "env", "provider", "engine", "mechanism",
            "username", "account", "access_key"
        ]
        let presentKeys = keyPriority.filter { key in
            signals.contains(where: { $0.name == key })
        }
        let markers = [
            signals.contains(where: { $0.name == "vhost" }) ? "amqp" : nil,
            signals.contains(where: { $0.name == "brokers" }) ? "brokers" : nil,
            signals.contains(where: { $0.name == "bucket" }) ? "bucket" : nil,
            signals.contains(where: { $0.name == "database" }) ? "db" : nil
        ].compactMap { $0 }
        let parts = Array((markers + presentKeys).prefix(6))
        return parts.isEmpty ? "freeform" : parts.joined(separator: "|")
    }

    private func suggestedClusterLabel(for clusterDecision: ClusterDecision, signals: [VaultSignal], templateType: String) -> String {
        let contextSource = firstSignalValue(in: signals, names: ["label", "service", "provider", "engine", "host", "url", "endpoint"])
        let normalizedSource = normalizedClusterSource(contextSource)

        switch clusterDecision.clusterID {
        case .humanAccountLogin:
            if let normalizedSource, !normalizedSource.isEmpty {
                return "\(normalizedSource) Account Access"
            }
            return "Account Access"
        case .serviceEndpointSecret:
            if let normalizedSource, !normalizedSource.isEmpty {
                return "\(normalizedSource) Service Access"
            }
            return "Service Endpoint Access"
        case .relationalDBCredential:
            if let engine = normalizedClusterSource(firstSignalValue(in: signals, names: ["engine"])), !engine.isEmpty {
                return "\(engine) Database Access"
            }
            return "Database Access"
        case .cacheCredential:
            if let normalizedSource, !normalizedSource.isEmpty {
                return "\(normalizedSource) Cache Access"
            }
            return "Cache Access"
        case .messageQueueCredential:
            if signals.contains(where: { $0.name == "vhost" }) {
                return "AMQP Queue Access"
            }
            if signals.contains(where: { $0.name == "brokers" }) {
                return "Kafka Stream Access"
            }
            return "Message Queue Access"
        case .objectStorageCredential:
            if let provider = normalizedClusterSource(firstSignalValue(in: signals, names: ["provider"])), !provider.isEmpty {
                return "\(provider) Object Storage Access"
            }
            return "Object Storage Access"
        case .cloudAccessPair:
            if let provider = normalizedClusterSource(firstSignalValue(in: signals, names: ["provider"])), !provider.isEmpty {
                return "\(provider) Cloud Access Pair"
            }
            return "Cloud Access Pair"
        case .genericSecretNote:
            if templateType != "custom" {
                return "\(humanizedTemplate(templateType)) Pattern"
            }
            if let normalizedSource, !normalizedSource.isEmpty {
                return "\(normalizedSource) Secret Pattern"
            }
            return "Custom Secret Pattern"
        }
    }

    private func firstSignalValue(in signals: [VaultSignal], names: [String]) -> String? {
        for name in names {
            if let signal = signals.first(where: { $0.name == name }), !signal.value.isEmpty {
                return signal.value
            }
        }
        return nil
    }

    private func normalizedClusterSource(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let host = URL(string: trimmed)?.host, !host.isEmpty {
            return host
        }
        if trimmed.uppercased() == trimmed {
            return trimmed
        }
        if trimmed.lowercased() == "github" {
            return "GitHub"
        }
        if trimmed.lowercased() == "gitlab" {
            return "GitLab"
        }
        return trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private func humanizedTemplate(_ templateType: String) -> String {
        switch templateType {
        case "s3":
            return "S3"
        case "aksk":
            return "AK/SK"
        default:
            return templateType
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }

    private func mergeRecordTags(_ tags: [String], templateType: String, clusterLabel: String?) -> [String] {
        var next = tags.filter { !$0.hasPrefix("cluster:") }
        if !next.contains(templateType) {
            next.append(templateType)
        }
        if let clusterLabel, !clusterLabel.isEmpty {
            next.append("cluster:\(clusterLabel)")
        }
        return Array(NSOrderedSet(array: next).array as? [String] ?? next)
    }

    private func inferTypeID(from text: String) -> String {
        let lowered = text.lowercased()
        if lowered.contains("redis") { return "redis" }
        if lowered.contains("kafka") || lowered.contains("brokers=") { return "kafka" }
        if lowered.contains("bucket") || lowered.contains("s3") || lowered.contains("access_key") { return "s3" }
        if lowered.contains("postgres") || lowered.contains("mysql") || lowered.contains("database") || lowered.contains("jdbc:") { return "database" }
        if lowered.contains("github") || lowered.contains("account") || lowered.contains("login") { return "account" }
        return "custom"
    }

    private func parseLocalPastedSecret(_ text: String) -> ParsedLocalSecret {
        let keyValues = extractKeyValues(from: text)
        let primarySecret = extractPrimarySecret(from: text, keyValues: keyValues)
        let signals = extractSignals(from: text, keyValues: keyValues, secret: primarySecret)
        let clusterDecision = decideCluster(for: signals, text: text, keyValues: keyValues)
        let templateType = deriveTemplateType(from: clusterDecision, text: text, keyValues: keyValues)
        let redactedExcerpt = redactExcerpt(text, secret: primarySecret)

        var fields: [VaultField] = []
        switch templateType {
        case "redis":
            fields = parseRedisFields(text, keyValues: keyValues)
        case "database":
            fields = parseDatabaseFields(text, keyValues: keyValues)
        case "s3":
            fields = parseS3Fields(keyValues: keyValues)
        case "kafka":
            fields = parseKafkaFields(keyValues: keyValues)
        case "aksk":
            fields = parseAKSKFields(keyValues: keyValues)
        case "account":
            fields = parseAccountFields(keyValues: keyValues)
        case "custom":
            fields = parseCustomFields(text, keyValues: keyValues)
        default:
            fields = parseGenericFields(keyValues: keyValues)
        }

        fields = enrichContextualFields(fields, text: text, keyValues: keyValues, secret: primarySecret)

        if let username = lookupValue(in: keyValues, keys: ["username", "user", "account", "login", "email", "sasl_username", "aws_access_key_id"]),
           !fields.contains(where: { $0.key == "username" }) {
            fields.insert(makeField(key: "username", label: "Username", value: username, semantic: "username", section: "Auth", order: 0), at: 0)
        }

        if let redactedExcerpt, !redactedExcerpt.isEmpty, !fields.contains(where: { $0.key == "source_excerpt" }) {
            fields.append(makeField(key: "source_excerpt", label: "Source Excerpt", value: String(redactedExcerpt.prefix(240)), semantic: "source_excerpt", section: "Metadata", order: 999))
        }

        let name = deriveRecordName(templateType: templateType, keyValues: keyValues, fields: fields)
        let notes = deriveNotes(templateType: templateType, keyValues: keyValues, redactedExcerpt: redactedExcerpt)
        let itemType = templateType == "account" ? "login" : "secret"
        return ParsedLocalSecret(
            itemType: itemType,
            templateType: templateType,
            clusterDecision: clusterDecision,
            signals: signals,
            name: name,
            notes: notes,
            tags: [templateType, "local"],
            fields: deduplicateFields(fields),
            primarySecret: primarySecret
        )
    }

    private func applyPastedFieldOverrides(to fields: [VaultField]) -> [VaultField] {
        fields.map { field in
            guard let override = pastedFieldOverrides[field.key] else { return field }
            var next = field
            next.value = override
            return next
        }
    }

    private func previewTags(from signals: [VaultSignal], fields: [VaultField], secret: String?, templateType: String) -> [String] {
        var tags: [String] = []

        for signal in prioritizedPreviewSignals(from: signals) {
            if let rendered = renderedSignalTag(signal), !rendered.isEmpty {
                tags.append(rendered)
            }
        }

        let prioritizedKeys = [
            "url", "endpoint", "host", "brokers",
            "service", "label", "account",
            "database", "bucket", "topic", "scope", "project", "vhost",
            "env", "region", "provider", "engine", "mechanism",
            "username", "access_key"
        ]

        for key in prioritizedKeys {
            if let value = fields.first(where: { $0.key == key })?.value,
               let rendered = renderedPreviewTag(forKey: key, value: value),
               !rendered.isEmpty {
                tags.append(rendered)
            }
        }

        let renderedSecret = secret.flatMap(renderedSecretTag)
        if let renderedSecret {
            tags.append(renderedSecret)
        }

        if tags.isEmpty {
            tags.append("source:\(templateType)")
        }

        var uniqueTags = Array(NSOrderedSet(array: tags).array as? [String] ?? tags)
        if let renderedSecret,
           let secretIndex = uniqueTags.firstIndex(of: renderedSecret),
           secretIndex >= 7 {
            uniqueTags.remove(at: secretIndex)
            if uniqueTags.count >= 7 {
                uniqueTags[6] = renderedSecret
            } else {
                uniqueTags.append(renderedSecret)
            }
        }
        return Array(uniqueTags.prefix(7))
    }

    private func prioritizedPreviewSignals(from signals: [VaultSignal]) -> [VaultSignal] {
        let priority: [String: Int] = [
            "url": 120, "endpoint": 120, "host": 115, "brokers": 110,
            "label": 105, "service": 105, "account": 95,
            "database": 90, "bucket": 90, "topic": 90, "scope": 85, "project": 85, "vhost": 85,
            "env": 80, "region": 75, "provider": 75, "engine": 70, "mechanism": 65,
            "username": 60, "access_key": 55
        ]
        return signals
            .filter { $0.category != .secret }
            .sorted { lhs, rhs in
                let lp = priority[lhs.name, default: 0]
                let rp = priority[rhs.name, default: 0]
                if lp != rp { return lp > rp }
                return lhs.name < rhs.name
            }
    }

    private func renderedSignalTag(_ signal: VaultSignal) -> String? {
        renderedPreviewTag(forKey: signal.name, value: signal.value)
    }

    private func renderedPreviewTag(forKey key: String, value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch key {
        case "url", "endpoint":
            if let host = URL(string: trimmed)?.host, !host.isEmpty {
                return "\(key):\(host)"
            }
            if let host = hostFromURLString(trimmed), !host.isEmpty {
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
        case "scope", "project", "vhost":
            return "\(key):\(trimmed)"
        case "env":
            return "env:\(trimmed)"
        case "region":
            return "region:\(trimmed)"
        case "provider":
            return "provider:\(trimmed)"
        case "engine":
            return "engine:\(trimmed)"
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

    private func renderedSecretTag(_ secret: String) -> String? {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let suffix = String(trimmed.suffix(min(4, trimmed.count)))
        return "secret:••••\(suffix)"
    }

    private func extractKeyValues(from text: String) -> [String: String] {
        let pattern = #"([A-Za-z_][A-Za-z0-9_\-\.]*)\s*[:=]\s*("[^"]+"|'[^']+'|[^\s]+)"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var pairs: [String: String] = [:]

        regex?.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match,
                  let keyRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else {
                return
            }
            let key = text[keyRange]
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: ".", with: "_")
            let value = text[valueRange].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty {
                pairs[key] = value
            }
        }
        return pairs
    }

    private func extractSignals(from text: String, keyValues: [String: String], secret: String?) -> [VaultSignal] {
        var signals: [VaultSignal] = []

        func append(_ category: SignalCategory, _ name: String, _ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let normalized = normalizeSignalValue(name: name, value: trimmed)
            guard !normalized.isEmpty else { return }
            signals.append(VaultSignal(category: category, name: name, value: trimmed, normalizedValue: normalized))
        }

        let explicitURL = lookupValue(in: keyValues, keys: ["url", "uri", "dsn", "site_url", "database_url", "jdbc_url", "redis_url"])
        let endpointURL = lookupValue(in: keyValues, keys: ["endpoint", "s3_endpoint"])
        let detectedURL = firstCapture(in: text, pattern: #"((?:https?|redis|postgresql|postgres|mysql|mariadb|clickhouse|mongodb|amqp)://[^\s]+)"#)

        append(.locator, "url", explicitURL ?? detectedURL)
        append(.locator, "endpoint", endpointURL)
        append(.locator, "host", lookupValue(in: keyValues, keys: ["host", "hostname"]) ?? hostFromURLString(explicitURL ?? endpointURL ?? detectedURL))
        append(.locator, "brokers", lookupValue(in: keyValues, keys: ["brokers", "bootstrap_servers", "bootstrap"]))
        append(.locator, "port", lookupValue(in: keyValues, keys: ["port"]))

        append(.principal, "username", lookupValue(in: keyValues, keys: ["username", "user", "login", "sasl_username"]))
        append(.principal, "account", lookupValue(in: keyValues, keys: ["account", "email"]))
        append(.principal, "access_key", lookupValue(in: keyValues, keys: ["access_key", "ak", "aws_access_key_id"]))

        let resourcePath = resourcePathFromURLString(explicitURL ?? detectedURL)
        append(.resource, "database", lookupValue(in: keyValues, keys: ["database", "dbname", "db"]) ?? resourcePath)
        append(.resource, "bucket", lookupValue(in: keyValues, keys: ["bucket"]))
        append(.resource, "topic", lookupValue(in: keyValues, keys: ["topic", "queue"]))
        append(.resource, "scope", lookupValue(in: keyValues, keys: ["scope", "project", "tenant"]))
        append(.resource, "project", lookupValue(in: keyValues, keys: ["project"]))
        append(.resource, "vhost", lookupValue(in: keyValues, keys: ["vhost"]) ?? (lowercasedScheme(in: explicitURL ?? detectedURL) == "amqp" ? resourcePath : nil))

        append(.context, "service", lookupValue(in: keyValues, keys: ["service", "site", "app", "cluster"]))
        append(.context, "label", lookupValue(in: keyValues, keys: ["label"]))
        append(.context, "env", lookupValue(in: keyValues, keys: ["env", "environment", "namespace", "stage"]))
        append(.context, "region", lookupValue(in: keyValues, keys: ["region", "aws_default_region"]))
        append(.context, "provider", lookupValue(in: keyValues, keys: ["provider", "cloud"]))
        append(.context, "engine", lookupValue(in: keyValues, keys: ["engine", "driver"]) ?? detectDatabaseEngine(in: text.lowercased()))
        append(.context, "mechanism", lookupValue(in: keyValues, keys: ["mechanism", "sasl_mechanism"]))

        if let secret, !secret.isEmpty {
            append(.secret, "secret_present", "true")
            append(.secret, "secret_carrier", detectSecretCarrier(in: text, keyValues: keyValues))
            append(.secret, "secret_suffix", String(secret.suffix(min(4, secret.count))))
        }

        return deduplicateSignals(signals)
    }

    private func decideCluster(for signals: [VaultSignal], text: String, keyValues: [String: String]) -> ClusterDecision {
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

        var scores: [CredentialClusterID: Int] = Dictionary(uniqueKeysWithValues: CredentialClusterID.allCases.map { ($0, 0) })
        var reasons: [CredentialClusterID: [String]] = Dictionary(uniqueKeysWithValues: CredentialClusterID.allCases.map { ($0, []) })

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
        if has("secret_present", in: .secret) { add(.serviceEndpointSecret, 10, "secret") }
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

        let best = scores.max(by: { lhs, rhs in lhs.value < rhs.value })
        let bestCluster = best?.key ?? .genericSecretNote
        let bestScore = best?.value ?? 0
        let confidence = min(0.99, max(0.2, Double(bestScore) / 90.0))
        let finalReasons = reasons[bestCluster, default: []]
        return ClusterDecision(clusterID: bestCluster, confidence: confidence, reasons: Array(finalReasons.prefix(4)))
    }

    private func deriveTemplateType(from clusterDecision: ClusterDecision, text: String, keyValues: [String: String]) -> String {
        let lowered = text.lowercased()

        switch clusterDecision.clusterID {
        case .humanAccountLogin:
            return "account"
        case .relationalDBCredential:
            return "database"
        case .cacheCredential:
            return "redis"
        case .messageQueueCredential:
            if lowered.contains("kafka") || keyValues.keys.contains("brokers") || keyValues.keys.contains("bootstrap_servers") {
                return "kafka"
            }
            return "custom"
        case .objectStorageCredential:
            return "s3"
        case .cloudAccessPair:
            if keyValues.keys.contains("bucket") || keyValues.keys.contains("s3_endpoint") {
                return "s3"
            }
            return "aksk"
        case .serviceEndpointSecret:
            return detectTemplateType(in: text, keyValues: keyValues)
        case .genericSecretNote:
            return detectTemplateType(in: text, keyValues: keyValues)
        }
    }

    private func detectTemplateType(in text: String, keyValues: [String: String]) -> String {
        let lowered = text.lowercased()
        let keys = Set(keyValues.keys)

        if lowered.contains("amqp://") || lowered.contains("rabbitmq") || keys.contains("vhost") {
            return "custom"
        }
        if lowered.contains("redis://") || lowered.contains("redis") {
            return "redis"
        }
        if lowered.contains("kafka") || keys.contains("brokers") || keys.contains("bootstrap_servers") || keys.contains("sasl_password") || keys.contains("topic") {
            return "kafka"
        }
        if lowered.contains("s3") || keys.contains("bucket") || (keys.contains("aws_access_key_id") && keys.contains("aws_secret_access_key")) || keys.contains("s3_endpoint") {
            return "s3"
        }
        if lowered.contains("postgresql://") || lowered.contains("postgres://") || lowered.contains("mysql://") || lowered.contains("mariadb://") || lowered.contains("clickhouse://") || lowered.contains("mongodb://") || lowered.contains("jdbc:") || keys.contains("database") || keys.contains("dbname") || (keys.contains("engine") && keyValues["engine"] != "rabbitmq") {
            return "database"
        }
        if (keys.contains("access_key") && keys.contains("secret_key")) || (keys.contains("ak") && keys.contains("sk")) {
            return "aksk"
        }
        if lowered.contains("github") || lowered.contains("gitlab") || lowered.contains("account") || lowered.contains("login") || keys.contains("service") || keys.contains("account") || keys.contains("email") {
            return "account"
        }
        return inferTypeID(from: text)
    }

    private func rankedLocalResults(for query: String, source: [VaultRecord]) -> [VaultRecord] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return [] }

        return source
            .compactMap { record in
                let score = localSearchScore(for: normalized, record: record)
                return score > 0 ? (record, score) : nil
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
            }
            .map(\.0)
    }

    private func localSearchScore(for normalizedQuery: String, record: VaultRecord) -> Int {
        var score = 0

        func bump(_ value: String?, contains: Int, exact: Int? = nil) {
            guard let value else { return }
            let lowered = value.lowercased()
            if let exact, lowered == normalizedQuery {
                score += exact
            } else if lowered.contains(normalizedQuery) {
                score += contains
            }
        }

        bump(record.title, contains: 120, exact: 180)
        bump(record.description, contains: 40, exact: 60)
        bump(record.recordType, contains: 10, exact: 20)

        for tag in record.tags {
            bump(tag, contains: 70, exact: 90)
        }

        if let clusterID = record.clusterID {
            bump(clusterID, contains: 20, exact: 30)
        }
        if let clusterLabel = record.clusterLabel {
            bump(clusterLabel, contains: 45, exact: 65)
        }

        let prioritizedFieldWeights: [String: Int] = [
            "label": 110,
            "service": 110,
            "url": 100,
            "endpoint": 100,
            "host": 95,
            "brokers": 90,
            "account": 85,
            "username": 75,
            "database": 85,
            "bucket": 85,
            "topic": 85,
            "scope": 75,
            "project": 75,
            "vhost": 75,
            "env": 70,
            "region": 65,
            "provider": 65,
            "engine": 60,
            "mechanism": 55,
            "access_key": 50
        ]

        for field in record.fields {
            let weight = prioritizedFieldWeights[field.key] ?? 25
            bump(field.value, contains: weight, exact: weight + 20)
        }

        let signalWeightsByCategory: [SignalCategory: Int] = [
            .locator: 95,
            .resource: 85,
            .context: 75,
            .principal: 70,
            .secret: 10
        ]
        if let signals = record.signals {
            for signal in signals {
                let baseWeight = signalWeightsByCategory[signal.category, default: 20]
                let exactWeight = baseWeight + 20
                bump(signal.normalizedValue, contains: baseWeight, exact: exactWeight)
            }
        }

        return score
    }

    private func extractPrimarySecret(from text: String, keyValues: [String: String]) -> String? {
        let secretKeys = [
            "password", "passwd", "pwd", "secret", "secret_key", "secretkey", "secret-key",
            "token", "sk", "sasl_password", "api_key", "apikey", "aws_secret_access_key",
            "rabbitmq_password", "rediscli_auth"
        ]
        for key in secretKeys {
            if let value = keyValues[key], !value.isEmpty {
                return value
            }
        }

        let patterns = [
            #"redis://(?:(?:[^:@/\s]+):)?([^@/\s]+)@[^/\s]+"#,
            #"(?:postgresql|postgres|mysql|mariadb|clickhouse|mongodb)://(?:(?:[^:@/\s]+):)?([^@/\s]+)@[^/\s]+"#,
            #"amqp://(?:(?:[^:@/\s]+):)?([^@/\s]+)@[^/\s]+"#,
            #"(?:password|secret|token)\s*[:=]\s*([^\s,;]+)"#
        ]
        for pattern in patterns {
            if let match = firstCapture(in: text, pattern: pattern) {
                return match.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    private func parseRedisFields(_ text: String, keyValues: [String: String]) -> [VaultField] {
        var fields: [VaultField] = []
        let pattern = #"redis://(?:(?:([^:@/\s]+):)?([^@/\s]+)@)?([^:/\s]+):(\d+)(?:/(\d+))?"#
        if let match = firstMatchGroups(in: text, pattern: pattern), match.count >= 5 {
            if let username = match[0], !username.isEmpty {
                fields.append(makeField(key: "username", label: "Username", value: username, semantic: "username", section: "Auth", order: 0))
            }
            if let host = match[2] {
                fields.append(makeField(key: "host", label: "Host", value: host, semantic: "host", section: "Connection", order: 1))
            }
            if let port = match[3] {
                fields.append(makeField(key: "port", label: "Port", value: port, valueType: "number", semantic: "port", section: "Connection", order: 2))
            }
            if let db = match[4], !db.isEmpty {
                fields.append(makeField(key: "db", label: "Database", value: db, valueType: "number", semantic: "database", section: "Connection", order: 3))
            }
            fields.append(makeField(key: "url", label: "URL", value: redactExcerpt(text, secret: extractPrimarySecret(from: text, keyValues: keyValues)) ?? text, valueType: "url", semantic: "uri", section: "Connection", order: 4))
            return fields
        }

        if let host = lookupValue(in: keyValues, keys: ["host", "hostname"]) {
            fields.append(makeField(key: "host", label: "Host", value: host, semantic: "host", section: "Connection", order: 1))
        }
        if let port = lookupValue(in: keyValues, keys: ["port"]) {
            fields.append(makeField(key: "port", label: "Port", value: port, valueType: "number", semantic: "port", section: "Connection", order: 2))
        }
        if let db = lookupValue(in: keyValues, keys: ["db", "database"]) {
            fields.append(makeField(key: "db", label: "Database", value: db, valueType: "number", semantic: "database", section: "Connection", order: 3))
        }
        if let url = lookupValue(in: keyValues, keys: ["url", "redis_url"]) {
            fields.append(makeField(key: "url", label: "URL", value: redactExcerpt(url, secret: extractPrimarySecret(from: text, keyValues: keyValues)) ?? url, valueType: "url", semantic: "uri", section: "Connection", order: 4))
        }
        return fields
    }

    private func parseDatabaseFields(_ text: String, keyValues: [String: String]) -> [VaultField] {
        var fields: [VaultField] = []
        let engine = lookupValue(in: keyValues, keys: ["engine", "driver"]) ?? detectDatabaseEngine(in: text.lowercased())
        if let engine {
            fields.append(makeField(key: "engine", label: "Engine", value: engine, semantic: "engine", section: "Connection", order: 1))
        }

        var urlValue = lookupValue(in: keyValues, keys: ["url", "uri", "dsn", "jdbc_url", "database_url", "redis_url", "endpoint", "s3_endpoint"])
        if urlValue == nil {
            urlValue = firstCapture(in: text, pattern: #"((?:postgresql|postgres|mysql|mariadb|clickhouse|mongodb)://[^\s]+)"#)
        }

        if let host = lookupValue(in: keyValues, keys: ["host", "hostname"]) {
            fields.append(makeField(key: "host", label: "Host", value: host, semantic: "host", section: "Connection", order: 2))
        }
        if let port = lookupValue(in: keyValues, keys: ["port"]) {
            fields.append(makeField(key: "port", label: "Port", value: port, valueType: "number", semantic: "port", section: "Connection", order: 3))
        }
        if let database = lookupValue(in: keyValues, keys: ["database", "dbname", "db"]) {
            fields.append(makeField(key: "database", label: "Database", value: database, semantic: "database", section: "Connection", order: 4))
        }

        if let urlValue, let components = URLComponents(string: urlValue) {
            if let host = components.host, !fields.contains(where: { $0.key == "host" }) {
                fields.append(makeField(key: "host", label: "Host", value: host, semantic: "host", section: "Connection", order: 2))
            }
            if let port = components.port, !fields.contains(where: { $0.key == "port" }) {
                fields.append(makeField(key: "port", label: "Port", value: String(port), valueType: "number", semantic: "port", section: "Connection", order: 3))
            }
            let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !path.isEmpty, !fields.contains(where: { $0.key == "database" }) {
                fields.append(makeField(key: "database", label: "Database", value: path, semantic: "database", section: "Connection", order: 4))
            }
            if let username = components.user, !fields.contains(where: { $0.key == "username" }) {
                fields.append(makeField(key: "username", label: "Username", value: username, semantic: "username", section: "Auth", order: 0))
            }
        }

        return fields
    }

    private func parseS3Fields(keyValues: [String: String]) -> [VaultField] {
        var fields: [VaultField] = []
        if let endpoint = lookupValue(in: keyValues, keys: ["endpoint", "s3_endpoint", "url", "host"]) {
            fields.append(makeField(key: "endpoint", label: "Endpoint", value: endpoint, valueType: "url", semantic: "endpoint", section: "Connection", order: 1))
        }
        if let bucket = lookupValue(in: keyValues, keys: ["bucket"]) {
            fields.append(makeField(key: "bucket", label: "Bucket", value: bucket, semantic: "bucket", section: "Connection", order: 2))
        }
        if let accessKey = lookupValue(in: keyValues, keys: ["access_key", "ak", "aws_access_key_id"]) {
            fields.append(makeField(key: "access_key", label: "Access Key", value: accessKey, semantic: "access_key", section: "Auth", order: 3))
        }
        if let region = lookupValue(in: keyValues, keys: ["region", "aws_default_region"]) {
            fields.append(makeField(key: "region", label: "Region", value: region, semantic: "region", section: "Connection", order: 4))
        }
        return fields
    }

    private func parseKafkaFields(keyValues: [String: String]) -> [VaultField] {
        var fields: [VaultField] = []
        if let brokers = lookupValue(in: keyValues, keys: ["brokers", "bootstrap_servers", "bootstrap"]) {
            fields.append(makeField(key: "brokers", label: "Brokers", value: brokers, semantic: "brokers", section: "Connection", order: 1))
        }
        if let mechanism = lookupValue(in: keyValues, keys: ["mechanism", "sasl_mechanism"]) {
            fields.append(makeField(key: "mechanism", label: "Mechanism", value: mechanism, semantic: "mechanism", section: "Auth", order: 2))
        }
        if let topic = lookupValue(in: keyValues, keys: ["topic"]) {
            fields.append(makeField(key: "topic", label: "Topic", value: topic, semantic: "topic", section: "Connection", order: 3))
        }
        if let username = lookupValue(in: keyValues, keys: ["sasl_username", "username", "user"]) {
            fields.append(makeField(key: "username", label: "Username", value: username, semantic: "username", section: "Auth", order: 0))
        }
        return fields
    }

    private func parseAKSKFields(keyValues: [String: String]) -> [VaultField] {
        var fields: [VaultField] = []
        if let provider = lookupValue(in: keyValues, keys: ["provider", "cloud"]) {
            fields.append(makeField(key: "provider", label: "Provider", value: provider, semantic: "provider", section: "Details", order: 1))
        }
        if let accessKey = lookupValue(in: keyValues, keys: ["access_key", "ak"]) {
            fields.append(makeField(key: "access_key", label: "Access Key", value: accessKey, semantic: "access_key", section: "Auth", order: 2))
        }
        if let scope = lookupValue(in: keyValues, keys: ["scope", "project", "tenant"]) {
            fields.append(makeField(key: "scope", label: "Scope", value: scope, semantic: "scope", section: "Details", order: 3))
        }
        if let region = lookupValue(in: keyValues, keys: ["region"]) {
            fields.append(makeField(key: "region", label: "Region", value: region, semantic: "region", section: "Details", order: 4))
        }
        return fields
    }

    private func parseAccountFields(keyValues: [String: String]) -> [VaultField] {
        var fields: [VaultField] = []
        if let service = lookupValue(in: keyValues, keys: ["service", "site", "provider"]) {
            fields.append(makeField(key: "service", label: "Service", value: service, semantic: "service", section: "Login", order: 1))
        }
        if let account = lookupValue(in: keyValues, keys: ["account", "email", "user", "username"]) {
            fields.append(makeField(key: "account", label: "Account", value: account, semantic: "account", section: "Login", order: 2))
        }
        if let url = lookupValue(in: keyValues, keys: ["url", "site_url", "uri"]) {
            fields.append(makeField(key: "url", label: "URL", value: url, valueType: "url", semantic: "uri", section: "Login", order: 3))
        }
        return fields
    }

    private func parseGenericFields(keyValues: [String: String]) -> [VaultField] {
        let secretKeys: Set<String> = [
            "password", "passwd", "pwd", "secret", "secret_key", "secretkey", "secret-key",
            "token", "sk", "sasl_password", "api_key", "apikey", "aws_secret_access_key",
            "rabbitmq_password", "rediscli_auth"
        ]
        var order = 1
        var fields: [VaultField] = []
        for (key, value) in keyValues.sorted(by: { $0.key < $1.key }) {
            guard !secretKeys.contains(key) else { continue }
            let valueType = key == "port" ? "number" : (["url", "uri", "dsn", "endpoint"].contains(key) ? "url" : "text")
            fields.append(makeField(key: key, label: humanizedFieldName(key), value: value, valueType: valueType, semantic: key, section: "Details", order: order))
            order += 1
        }
        return fields
    }

    private func parseCustomFields(_ text: String, keyValues: [String: String]) -> [VaultField] {
        if text.lowercased().contains("amqp://") || text.lowercased().contains("rabbitmq") || keyValues.keys.contains("vhost") {
            return parseRabbitMQFields(text, keyValues: keyValues)
        }
        return parseGenericFields(keyValues: keyValues)
    }

    private func enrichContextualFields(_ fields: [VaultField], text: String, keyValues: [String: String], secret: String?) -> [VaultField] {
        var enriched = fields

        func appendIfMissing(
            key: String,
            label: String,
            value: String?,
            valueType: String = "text",
            semantic: String? = nil,
            section: String,
            order: Int
        ) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard !enriched.contains(where: { $0.key == key }) else { return }
            enriched.append(makeField(key: key, label: label, value: trimmed, valueType: valueType, semantic: semantic, section: section, order: order))
        }

        let explicitURL = lookupValue(in: keyValues, keys: ["url", "uri", "site_url", "dsn", "database_url", "redis_url", "jdbc_url"])
        let endpointURL = lookupValue(in: keyValues, keys: ["endpoint", "s3_endpoint"])
        let detectedURL = firstCapture(in: text, pattern: #"((?:https?|redis|postgresql|postgres|mysql|mariadb|clickhouse|mongodb|amqp)://[^\s]+)"#)
        appendIfMissing(
            key: "url",
            label: "URL",
            value: redactExcerpt(explicitURL ?? detectedURL ?? endpointURL ?? "", secret: secret),
            valueType: "url",
            semantic: "uri",
            section: "Connection",
            order: 90
        )

        appendIfMissing(
            key: "label",
            label: "Label",
            value: lookupValue(in: keyValues, keys: ["label", "service", "site", "app", "cluster"]),
            semantic: "label",
            section: "Metadata",
            order: 91
        )
        appendIfMissing(
            key: "env",
            label: "Environment",
            value: lookupValue(in: keyValues, keys: ["env", "environment", "namespace", "stage"]),
            semantic: "environment",
            section: "Metadata",
            order: 92
        )
        appendIfMissing(
            key: "region",
            label: "Region",
            value: lookupValue(in: keyValues, keys: ["region", "aws_default_region"]),
            semantic: "region",
            section: "Metadata",
            order: 93
        )
        appendIfMissing(
            key: "provider",
            label: "Provider",
            value: lookupValue(in: keyValues, keys: ["provider", "cloud"]),
            semantic: "provider",
            section: "Metadata",
            order: 94
        )
        appendIfMissing(
            key: "account",
            label: "Account",
            value: lookupValue(in: keyValues, keys: ["account", "email", "login", "user", "username", "sasl_username"]),
            semantic: "account",
            section: "Auth",
            order: 95
        )
        appendIfMissing(
            key: "database",
            label: "Database",
            value: lookupValue(in: keyValues, keys: ["database", "dbname", "db"]),
            semantic: "database",
            section: "Connection",
            order: 96
        )
        appendIfMissing(
            key: "bucket",
            label: "Bucket",
            value: lookupValue(in: keyValues, keys: ["bucket"]),
            semantic: "bucket",
            section: "Connection",
            order: 97
        )
        appendIfMissing(
            key: "topic",
            label: "Topic",
            value: lookupValue(in: keyValues, keys: ["topic", "queue"]),
            semantic: "topic",
            section: "Connection",
            order: 98
        )
        appendIfMissing(
            key: "scope",
            label: "Scope",
            value: lookupValue(in: keyValues, keys: ["scope", "project", "tenant"]),
            semantic: "scope",
            section: "Metadata",
            order: 99
        )
        appendIfMissing(
            key: "host",
            label: "Host",
            value: lookupValue(in: keyValues, keys: ["host", "hostname"]) ?? hostFromURLString(explicitURL ?? endpointURL ?? detectedURL),
            semantic: "host",
            section: "Connection",
            order: 100
        )

        return enriched
    }

    private func parseRabbitMQFields(_ text: String, keyValues: [String: String]) -> [VaultField] {
        var fields: [VaultField] = []
        let pattern = #"amqp://(?:(?:([^:@/\s]+):)?([^@/\s]+)@)?([^:/\s]+):(\d+)(?:/([^\s]+))?"#
        if let match = firstMatchGroups(in: text, pattern: pattern), match.count >= 5 {
            if let username = match[0], !username.isEmpty {
                fields.append(makeField(key: "username", label: "Username", value: username, semantic: "username", section: "Auth", order: 0))
            }
            if let host = match[2], !host.isEmpty {
                fields.append(makeField(key: "host", label: "Host", value: host, semantic: "host", section: "Connection", order: 1))
            }
            if let port = match[3], !port.isEmpty {
                fields.append(makeField(key: "port", label: "Port", value: port, valueType: "number", semantic: "port", section: "Connection", order: 2))
            }
            if let vhost = match[4], !vhost.isEmpty {
                fields.append(makeField(key: "vhost", label: "VHost", value: vhost, semantic: "vhost", section: "Connection", order: 3))
            }
            return fields
        }

        if let host = lookupValue(in: keyValues, keys: ["host", "hostname"]) {
            fields.append(makeField(key: "host", label: "Host", value: host, semantic: "host", section: "Connection", order: 1))
        }
        if let port = lookupValue(in: keyValues, keys: ["port"]) {
            fields.append(makeField(key: "port", label: "Port", value: port, valueType: "number", semantic: "port", section: "Connection", order: 2))
        }
        if let vhost = lookupValue(in: keyValues, keys: ["vhost"]) {
            fields.append(makeField(key: "vhost", label: "VHost", value: vhost, semantic: "vhost", section: "Connection", order: 3))
        }
        if let engine = lookupValue(in: keyValues, keys: ["engine"]), !engine.isEmpty {
            fields.append(makeField(key: "engine", label: "Engine", value: engine, semantic: "engine", section: "Details", order: 4))
        }
        return fields
    }

    private func deriveRecordName(templateType: String, keyValues: [String: String], fields: [VaultField]) -> String {
        let target = lookupValue(in: keyValues, keys: ["service", "bucket", "host", "database", "account", "provider"])
        if templateType == "database", let target {
            let engine = lookupValue(in: keyValues, keys: ["engine", "driver"]) ?? detectDatabaseEngine(in: keyValues.values.joined(separator: " ").lowercased())
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

    private func deriveNotes(templateType: String, keyValues: [String: String], redactedExcerpt: String?) -> String {
        let env = lookupValue(in: keyValues, keys: ["env", "environment", "namespace"])
        let target = lookupValue(in: keyValues, keys: ["service", "bucket", "database", "topic", "host"])
        let parts = [env, target].compactMap { $0 }
        if !parts.isEmpty {
            return "\(templateType.uppercased()) credential for \(parts.joined(separator: " / "))"
        }
        if let redactedExcerpt, !redactedExcerpt.isEmpty {
            return String(redactedExcerpt.prefix(140))
        }
        return "\(templateType.uppercased()) credential"
    }

    private func detectDatabaseEngine(in lowered: String) -> String? {
        for engine in ["postgres", "postgresql", "mysql", "mariadb", "clickhouse", "oracle", "sqlserver", "mongodb"] {
            if lowered.contains(engine) {
                return engine == "postgresql" ? "postgres" : engine
            }
        }
        return nil
    }

    private func detectSecretCarrier(in text: String, keyValues: [String: String]) -> String {
        let lowered = text.lowercased()
        let prioritizedKeys = [
            "password", "passwd", "pwd", "secret", "secret_key", "token",
            "sk", "sasl_password", "api_key", "apikey", "aws_secret_access_key"
        ]
        if let matchedKey = prioritizedKeys.first(where: { keyValues[$0] != nil }) {
            return matchedKey
        }
        if lowered.contains("://") && lowered.contains("@") {
            return "inline_uri_auth"
        }
        return "freeform_secret"
    }

    private func normalizeSignalValue(name: String, value: String) -> String {
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

    private func redactExcerpt(_ text: String, secret: String?) -> String? {
        guard !text.isEmpty else { return nil }
        guard let secret, !secret.isEmpty else { return text }
        return text.replacingOccurrences(of: secret, with: "[REDACTED]")
    }

    private func deduplicateFields(_ fields: [VaultField]) -> [VaultField] {
        var seen: [String: VaultField] = [:]
        for field in fields {
            seen[field.key] = field
        }
        return seen.values.sorted { lhs, rhs in
            (lhs.section ?? "", lhs.order, lhs.label) < (rhs.section ?? "", rhs.order, rhs.label)
        }
    }

    private func deduplicateSignals(_ signals: [VaultSignal]) -> [VaultSignal] {
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

    private func clusterPreferredValue(for record: VaultRecord, names: [String]) -> String? {
        if let signals = record.signals {
            for name in names {
                if let signal = signals.first(where: { $0.name == name }) {
                    return signal.value
                }
            }
        }
        for name in names {
            if let value = record.fieldMap[name] {
                return value
            }
        }
        return nil
    }

    private func sortRecordsWithinCluster(_ records: [VaultRecord]) -> [VaultRecord] {
        records.sorted { lhs, rhs in
            let schemaFields = lhs.clusterSchemaDefinition.fields
            for field in schemaFields {
                let lhsValue = clusterSortValue(for: lhs, keys: field.keys)
                let rhsValue = clusterSortValue(for: rhs, keys: field.keys)
                if lhsValue != rhsValue {
                    if lhsValue.isEmpty { return false }
                    if rhsValue.isEmpty { return true }
                    return lhsValue.localizedCaseInsensitiveCompare(rhsValue) == .orderedAscending
                }
            }

            if lhs.title != rhs.title {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    private func clusterSortValue(for record: VaultRecord, keys: [String]) -> String {
        clusterPreferredValue(for: record, names: keys)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func lookupValue(in keyValues: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let value = keyValues[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func hostFromURLString(_ candidate: String?) -> String? {
        guard let candidate, !candidate.isEmpty else { return nil }
        if let host = URL(string: candidate)?.host, !host.isEmpty {
            return host
        }
        // URIs with unencoded characters in the userinfo (e.g. "#" in a password)
        // make URL(string:) lose the host; parse the authority textually instead.
        // The "#" must stay part of the authority here: it can appear inside the
        // password before the "@" separator.
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

    private func resourcePathFromURLString(_ candidate: String?) -> String? {
        guard let candidate, !candidate.isEmpty,
              let components = URLComponents(string: candidate) else {
            return nil
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? nil : path
    }

    private func lowercasedScheme(in candidate: String?) -> String? {
        guard let candidate, !candidate.isEmpty,
              let scheme = URLComponents(string: candidate)?.scheme else {
            return nil
        }
        return scheme.lowercased()
    }

    private var prioritizedEditingSignalKeys: [String] {
        [
            "label", "service", "account", "username",
            "url", "endpoint", "host", "brokers",
            "database", "bucket", "topic", "scope", "project", "vhost",
            "env", "region", "provider", "engine", "mechanism", "access_key"
        ]
    }

    private func makeField(
        key: String,
        label: String,
        value: String,
        valueType: String = "text",
        semantic: String? = nil,
        section: String,
        order: Int
    ) -> VaultField {
        VaultField(
            key: key,
            label: label,
            value: value,
            valueType: valueType,
            semantic: semantic,
            hidden: false,
            section: section,
            order: order
        )
    }

    private func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    private func firstMatchGroups(in text: String, pattern: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        return (1..<match.numberOfRanges).map { index in
            guard let captureRange = Range(match.range(at: index), in: text) else {
                return nil
            }
            return String(text[captureRange])
        }
    }

    private func makeVaultFields() -> [VaultField] {
        var fields: [VaultField] = []
        var consumedKeys = Set<String>()
        if !recordUsername.isEmpty {
            fields.append(VaultField(key: "username", label: "Username", value: recordUsername, valueType: "text", semantic: "username", hidden: false, section: "Auth", order: 0))
            consumedKeys.insert("username")
        }

        for (order, templateField) in selectedType.fields.enumerated() {
            let value = recordFields[templateField.key, default: ""]
            guard !value.isEmpty else { continue }
            if templateField.key == "username" {
                continue
            }
            consumedKeys.insert(templateField.key)
            fields.append(
                VaultField(
                    key: templateField.key,
                    label: templateField.label,
                    value: value,
                    valueType: templateField.valueType,
                    semantic: templateField.semantic,
                    hidden: false,
                    section: templateField.section,
                    order: order + 1
                )
            )
        }

        let remainingKeys = recordFields.keys
            .filter { key in
                !consumedKeys.contains(key)
                    && key != "source_excerpt"
                    && !(recordFields[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .sorted()

        for (offset, key) in remainingKeys.enumerated() {
            let value = recordFields[key, default: ""]
            let valueType: String
            if key == "port" {
                valueType = "number"
            } else if ["url", "uri", "endpoint"].contains(key) {
                valueType = "url"
            } else {
                valueType = "text"
            }
            fields.append(
                VaultField(
                    key: key,
                    label: humanizedFieldName(key),
                    value: value,
                    valueType: valueType,
                    semantic: key,
                    hidden: false,
                    section: "Details",
                    order: 100 + offset
                )
            )
        }
        return fields
    }
}
