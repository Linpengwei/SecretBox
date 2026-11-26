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
    // The value map alone cannot carry VaultField.hidden through an edit.
    private var recordHiddenFieldKeys: Set<String> = []
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
    // Server AI gateway: availability is detected from the server, the
    // preference to use it is local (persisted, never pushed to the server).
    @Published var serverAIAvailable = false
    @Published var serverAIModel: String?
    @Published var useServerAI = false {
        didSet {
            defaults.set(useServerAI, forKey: Self.useServerAIKey)
        }
    }

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
    private static let useServerAIKey = "SecretBox.useServerAI"
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
        useServerAI = defaults.bool(forKey: Self.useServerAIKey)
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
                tags: ["totp", "verification"],
                highlights: ["Authenticator: \(totp.issuer ?? totp.account ?? "Unnamed")"],
                hasSecret: false,
                editableFields: [],
                hasTOTP: true
            )
        }
        let parsed = parseLocalPastedSecret(parseableText)
        let effectiveType = pastedTypeOverride.isEmpty ? parsed.templateType : pastedTypeOverride
        let fields = parsed.fields
        let highlights = fields
            .filter { $0.key != "source_excerpt" }
            .prefix(4)
            .map { "\($0.label): \($0.value)" }
        var previewTags = CaptureParser.previewTags(signals: parsed.signals, fields: fields, secret: parsed.primarySecret, templateType: effectiveType)
        if capturedTOTP != nil {
            previewTags.append("verification")
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
        await refreshServerAIStatus()
    }

    /// Probe the server AI gateway. When the server has an AI provider
    /// configured, the "use server AI" option becomes available in settings;
    /// if the server later loses its configuration, the local preference
    /// falls back off instead of silently routing AI calls at a dead gateway.
    func refreshServerAIStatus() async {
        guard !shouldSkipServerCalls else {
            serverAIAvailable = providerConfigured
            serverAIModel = providerConfigured ? providerModel : nil
            return
        }
        do {
            let status = try await api.fetchAIStatus(baseURL: serverURL)
            serverAIAvailable = status.enabled
            serverAIModel = status.enabled ? status.model : nil
            if useServerAI && !status.enabled {
                useServerAI = false
                statusMessage = "Server AI is no longer configured"
            }
        } catch {
            serverAIAvailable = false
            serverAIModel = nil
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

        // With the server AI gateway selected the provider lives entirely on
        // the server (managed via the dashboard); pushing the local fields
        // would overwrite that configuration with whatever happens to be in
        // the form.
        if useServerAI {
            await refreshServerAIStatus()
            statusMessage = "Using server AI\(serverAIModel.map { " (\($0))" } ?? "")"
            return
        }

        do {
            let payload = ProviderSettingsPayload(baseURL: providerBaseURL, apiKey: providerAPIKey, model: providerModel)
            let settings = try await api.saveProviderSettings(baseURL: serverURL, payload: payload)
            providerConfigured = settings.configured
            providerAPIKey = ""
            await refreshServerAIStatus()
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
                primarySecret: recordPassword,
                matchReason: isEditingRecord ? "updated locally for testing" : "saved locally for testing",
                aiReadable: recordPermissions.aiAccess == .metadataAndTools,
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
                    primarySecret: nil,
                    matchReason: "saved locally from pasted TOTP URI",
                    aiReadable: recordPermissions.aiAccess == .metadataAndTools,
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
            let effectiveFields = parsed.fields
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
                primarySecret: parsed.primarySecret,
                matchReason: "saved locally from pasted text",
                aiReadable: recordPermissions.aiAccess == .metadataAndTools,
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
            let parsed = parseLocalPastedSecret(parseableText)
            let effectiveType = pastedTypeOverride.isEmpty ? parsed.templateType : pastedTypeOverride
            let effectiveTitle = pastedTitleOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveNote = pastedNoteOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            let structured = !parseableText.isEmpty
            let record = try await api.saveRecord(
                baseURL: serverURL,
                payload: VaultItemCreateRequest(
                    itemType: structured ? parsed.itemType : "secret",
                    templateType: structured ? effectiveType : nil,
                    name: structured ? (effectiveTitle.isEmpty ? parsed.name : effectiveTitle) : "",
                    // The capture engine has already read the paste. Do not
                    // send raw pasted_text a second time; only the TOTP-only
                    // compatibility path still needs the URI routed server-side.
                    pastedText: structured ? "" : normalized,
                    primarySecret: structured ? parsed.primarySecret : nil,
                    notes: structured ? (effectiveNote.isEmpty ? parsed.notes : effectiveNote) : "",
                    tags: structured ? [effectiveType] : [],
                    fields: structured ? parsed.fields : [],
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
            // The demo records are UI-test and snapshot fixtures. A real user
            // with an empty vault gets an empty result, never a fake "Prod S3
            // Bucket" whose placeholder secret could be copied by mistake.
            let source = localRecords.isEmpty && isUITesting ? seededRecords : localRecords
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
        concealSecrets(ofRecord: id)
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
        // Legacy boolean mirror for pre-matrix MCP builds, fail-closed: those
        // builds read `true` as full tool access, so it may only be set for
        // the level that actually grants it — never for metadata-only.
        localRecords[index].aiReadable = level == .metadataAndTools
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

    /// Copies a password. It leaves the clipboard again on its own
    /// (`PlatformClipboard.secretClearDelay`).
    func copyPassword(_ password: String) {
        PlatformClipboard.copySecret(password)
        statusMessage = "Password copied"
    }

    /// Copies a verification code, with the same self-clearing clipboard write.
    func copyTOTPCode(_ code: String) {
        PlatformClipboard.copySecret(code)
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

    // MARK: - Reveal on demand (detail pane)

    /// Shown in place of a secret-class value until the user reveals it. A
    /// fixed length, so it gives nothing about the real value away.
    static let secretMask = String(repeating: "•", count: 12)

    /// Secret-class values the user currently sees in the clear, keyed by
    /// `"<record id>::<key>"`. Empty means everything is masked.
    @Published private(set) var revealedSecretKeys: Set<String> = []

    private static func secretStorageKey(_ record: VaultRecord, _ key: String) -> String {
        "\(record.id)::\(key)"
    }

    func isSecretRevealed(_ record: VaultRecord, key: String) -> Bool {
        !record.effectivePermissions.hideSecret && revealedSecretKeys.contains(Self.secretStorageKey(record, key))
    }

    /// What the detail pane shows for a secret-class value (the password, or a
    /// field flagged hidden): the value while revealed, the mask otherwise.
    func displayedSecret(_ record: VaultRecord, key: String, value: String) -> String {
        isSecretRevealed(record, key: key) ? value : Self.secretMask
    }

    /// Reveals or masks a secret-class value. Revealing is a secret use: a
    /// record carrying the re-auth permission asks for Touch ID first. A record
    /// with the hide-secret permission is never displayed.
    func toggleSecretReveal(_ record: VaultRecord, key: String, label: String) async {
        guard !record.effectivePermissions.hideSecret else { return }
        let storageKey = Self.secretStorageKey(record, key)
        if revealedSecretKeys.contains(storageKey) {
            revealedSecretKeys.remove(storageKey)
            return
        }
        guard await requestSecretUse(for: record, action: "reveal \(label.lowercased())") else { return }
        revealedSecretKeys.insert(storageKey)
    }

    /// Masks a record's secrets again — whenever its content changes or it
    /// goes away, so an edited password is not simply shown in the clear.
    func concealSecrets(ofRecord id: String) {
        revealedSecretKeys = revealedSecretKeys.filter { !$0.hasPrefix("\(id)::") }
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

    /// Same source as the main-window local search: the user's records. The
    /// demo seeds appear only in UI tests, and only when the vault is empty.
    private var quickAccessSource: [VaultRecord] {
        localRecords.isEmpty && isUITesting ? seededRecords : localRecords
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

    func isFieldHidden(_ key: String) -> Bool {
        recordHiddenFieldKeys.contains(key) || CaptureRules.isSecretKey(key)
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
        // Compiled out of release builds. The hooks behind this flag reset
        // vault and preference state, so no environment variable may ever
        // reach them in a shipped app.
        #if DEBUG
        return environment["SECRETBOX_UI_TEST"] == "1"
        #else
        return false
        #endif
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

        // Hermetic start for UI tests: whatever a previous run left behind
        // (in the private test suite, see SecretBoxApp) must not leak in.
        localRecords = []
        recordStore.clear()
        for key in [
            Self.localRecordsKey, Self.serverEnabledKey, Self.useServerAIKey,
            Self.organizationLastRunKey, Self.organizationThresholdBucketKey,
            Self.organizationSummaryKey, Self.organizationIntervalDaysKey,
            Self.recentQuickAccessKey,
        ] {
            defaults.removeObject(forKey: key)
        }
        serverEnabled = false
        useServerAI = false
        recentQuickAccessIDs = []
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
        recordHiddenFieldKeys = []
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
        recordHiddenFieldKeys = Set(record.fields.filter(\.hidden).map(\.key))
        syncRecordFieldsWithSelectedType()
    }

    private func classifyEditorDraft() -> (itemType: String, templateType: String, clusterDecision: ClusterDecision, signals: [VaultSignal], tags: [String], defaultName: String, defaultNotes: String) {
        let keyValues = editorDraftKeyValues()
        let synthesizedText = editorDraftText(from: keyValues)
        let primarySecret = recordPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : recordPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let labels = Set(keyValues.keys)
        let signals = CaptureClassification.signals(
            text: synthesizedText,
            keyValues: keyValues,
            labels: labels,
            secret: primarySecret,
            hasURICredential: false
        )
        let clusterDecision = CaptureClassification.decideCluster(for: signals, text: synthesizedText, keyValues: keyValues)
        let templateType = CaptureClassification.templateType(
            for: clusterDecision,
            text: synthesizedText,
            keyValues: keyValues,
            labels: labels,
            secretScheme: nil
        )
        let fields = makeVaultFields()
        let redactedExcerpt = CaptureExtraction.scrub(synthesizedText, secret: primarySecret)
        let defaultName = CaptureClassification.recordName(templateType: templateType, keyValues: keyValues, fields: fields)
        let defaultNotes = CaptureClassification.notes(templateType: templateType, keyValues: keyValues, fallback: redactedExcerpt)
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
        // New content: anything the user had revealed is masked again.
        concealSecrets(ofRecord: record.id)
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
        CaptureExtraction.normalize(text)
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
        let labels = Set(keyValues.keys)
        let signals = CaptureClassification.signals(
            text: synthesizedText,
            keyValues: keyValues,
            labels: labels,
            secret: secret,
            hasURICredential: false
        )
        let clusterDecision = CaptureClassification.decideCluster(for: signals, text: synthesizedText, keyValues: keyValues)
        let derivedTemplateType = CaptureClassification.templateType(
            for: clusterDecision,
            text: synthesizedText,
            keyValues: keyValues,
            labels: labels,
            secretScheme: nil
        )

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
        let mergedSignals = CaptureClassification.deduplicated(records.flatMap { $0.signals ?? [] })
        let mergedKeyValues = records.reduce(into: [String: String]()) { partialResult, record in
            for field in record.fields where partialResult[field.key] == nil && !field.value.isEmpty {
                partialResult[field.key] = field.value
            }
        }
        let mergedText = records
            .map { normalizeUnstructuredInput(organizationSourceText(for: $0, keyValues: $0.fieldMap)) }
            .joined(separator: " ")
        let clusterDecision = CaptureClassification.decideCluster(for: mergedSignals, text: mergedText, keyValues: mergedKeyValues)
        let templateType = CaptureClassification.templateType(
            for: clusterDecision,
            text: mergedText,
            keyValues: mergedKeyValues,
            labels: Set(mergedKeyValues.keys),
            secretScheme: nil
        )
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

    private func parseLocalPastedSecret(_ text: String) -> ParsedLocalSecret {
        let capture = CaptureParser.parse(
            text,
            overrides: pastedFieldOverrides,
            typeOverride: pastedTypeOverride.isEmpty ? nil : pastedTypeOverride
        )
        return ParsedLocalSecret(
            itemType: capture.itemType,
            templateType: capture.templateType,
            clusterDecision: capture.clusterDecision,
            signals: capture.signals,
            name: capture.name,
            notes: capture.notes,
            tags: [capture.templateType, "local"],
            fields: capture.fields,
            primarySecret: capture.primarySecret
        )
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

    private var prioritizedEditingSignalKeys: [String] {
        [
            "label", "service", "account", "username",
            "url", "endpoint", "host", "brokers",
            "database", "bucket", "topic", "scope", "project", "vhost",
            "env", "region", "provider", "engine", "mechanism", "access_key"
        ]
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
                    hidden: isFieldHidden(templateField.key),
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
                    hidden: isFieldHidden(key),
                    section: "Details",
                    order: 100 + offset
                )
            )
        }
        return fields
    }
}
