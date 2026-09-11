import SwiftUI

struct VaultItemEditorView: View {
    @ObservedObject var model: SecretBoxAppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var showDeleteConfirmation = false
    @State private var previewFieldsExpanded = false
    #if os(iOS)
    @State private var showTOTPScanner = false
    #endif

    var body: some View {
        Group {
            if model.isEditingRecord {
                editBody
            } else {
                captureBody
            }
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 560, alignment: .topLeading)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #endif
        .background(AppTheme.pageBackground(colorScheme))
    }

    private var captureBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Quick Capture")
                            .font(.title2.weight(.semibold))
                        Text("Paste loose text. SecretBox will organize it using internal templates and clustering.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $model.pastedText)
                            .font(.body)
                            .padding(8)
                            .scrollContentBackground(.hidden)
                            .background(AppTheme.controlBackground(colorScheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .accessibilityIdentifier("capture.paste")

                        if model.pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Paste passwords, connection strings, account snippets, or any unstructured text here")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .padding(.top, 20)
                                .padding(.leading, 20)
                                .allowsHitTesting(false)
                        }
                    }
                    #if os(macOS)
                    .frame(minHeight: 220)
                    #else
                    .frame(minHeight: 150)
                    #endif

                    Toggle(isOn: Binding(
                        get: { model.recordPermissions.aiAccess != .none },
                        set: { model.recordPermissions.aiAccess = $0 ? .metadataAndTools : .none }
                    )) {
                        Text("Open to AI reading")
                            .font(.callout.weight(.medium))
                        Text("Once enabled, the MCP agent (Claude Code / OpenCode / Codex) can query the metadata of this record and copy its password via the clipboard. Disabled by default.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("capture.aiReadable")

                    if let preview = model.pastedSecretPreview {
                        previewCard(preview)
                            .accessibilityIdentifier("capture.preview")
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .accessibilityIdentifier("editor.scroll")
            .scrollDismissesKeyboard(.immediately)

            HStack {
                Spacer()
                Button("Cancel") {
                    model.dismissEditor()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save Capture") {
                    Task { await model.saveFromPastedText() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("capture.save")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
        }
    }

    private var editBody: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Edit Item")
                            .font(.title2.weight(.semibold))
                        Text("Update the saved details when parsing needs a manual correction.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !model.editingSignals.isEmpty || model.editingClusterSummary != nil {
                        editingContextCard
                    }

                    identityFields

                    ForEach(model.editingFieldGroups, id: \.title) { group in
                        fieldSection(group)
                    }

                    TextField("Description or note", text: $model.recordNote, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("entry.note")

                    totpSection
                        .id("totp")

                    permissionSection
                        .id("permissions")
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .accessibilityIdentifier("editor.scroll")
            .scrollDismissesKeyboard(.immediately)
            .task {
                if let anchor = model.uiTestEditorScrollAnchor {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    withAnimation { scrollProxy.scrollTo(anchor, anchor: .center) }
                }
            }

            HStack {
                if model.isEditingRecord, let editingID = model.editingRecordID {
                    Button("Delete Record", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                    .disabled(model.editingRecordIsLocked)
                    .accessibilityIdentifier("editor.delete")
                    .confirmationDialog(
                        "Delete this record?",
                        isPresented: $showDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Delete", role: .destructive) {
                            model.deleteRecord(id: editingID)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes the record from this Mac. Records already saved on a server are not affected in this beta.")
                    }
                }

                Spacer()

                Button("Cancel") {
                    model.dismissEditor()
                }
                .keyboardShortcut(.cancelAction)

                Button("Update Item") {
                    Task { await model.saveRecord() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("entry.save")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
        }
    }

    /// Title / username / password share one row where width allows and
    /// stack on compact widths (iPhone portrait) so no field collapses.
    @ViewBuilder
    private var identityFields: some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 12) {
            titleField
            usernameField
            passwordField
        }
        #else
        VStack(alignment: .leading, spacing: 12) {
            titleField
            HStack(alignment: .top, spacing: 12) {
                usernameField
                passwordField
            }
        }
        #endif
    }

    private var editingContextCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Detected Context")
                    .font(.headline)
                Spacer()
                if let summary = model.editingClusterSummary {
                    Text(summary)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            let tags = editingContextTags
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(AppTheme.pageBackground(colorScheme), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(AppTheme.controlBackground(colorScheme), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func previewCard(_ preview: PastedSecretPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Detected Preview")
                    .font(.headline)
                Spacer()
                if preview.hasSecret {
                    Text("Secret detected")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if !preview.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(preview.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(AppTheme.pageBackground(colorScheme), in: Capsule())
                        }
                    }
                }
            }

            if preview.hasTOTP {
                Label("已检测到两步验证：otpauth:// 种子将保存为该条目的验证码来源", systemImage: "timer.badge.checkmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.brand)
            }

            if !preview.editableFields.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Detected Fields")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if preview.editableFields.count > 4 {
                            Button(previewFieldsExpanded ? "Collapse" : "Show all") {
                                previewFieldsExpanded.toggle()
                            }
                            .buttonStyle(.plain)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("capture.previewFieldsToggle")
                        }
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(previewFields(for: preview)) { field in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(field.label)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                TextField(field.label, text: model.bindingForPastedField(field))
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityIdentifier("capture.previewField.\(field.key)")
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(AppTheme.controlBackground(colorScheme), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func previewFields(for preview: PastedSecretPreview) -> [PastedPreviewField] {
        if previewFieldsExpanded || preview.editableFields.count <= 4 {
            return preview.editableFields
        }
        return Array(preview.editableFields.prefix(4))
    }

    private var titleField: some View {
        TextField("Item title", text: $model.recordTitle)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("entry.title")
    }

    private var usernameField: some View {
        TextField("Username", text: $model.recordUsername)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("entry.username")
    }

    private var passwordField: some View {
        SecureField("Password", text: $model.recordPassword)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("entry.password")
    }

    private func fieldSection(_ group: (title: String, keys: [String])) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(group.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                ForEach(group.keys, id: \.self) { key in
                    TextField(model.humanizedFieldName(key), text: Binding(
                        get: { model.recordFields[key, default: ""] },
                        set: { model.updateField(key, value: $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    // MARK: - Two-step verification (TOTP)

    /// Parsed preview of the draft input; nil with non-empty input means the
    /// seed/URI is invalid and saving is blocked.
    private var draftTOTPParsed: TOTPSecret? {
        let trimmed = model.recordTOTPInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return TOTPSecret.fromUserInput(trimmed)
    }

    private var totpSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("两步验证 (TOTP)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if model.recordTOTPRemoveRequested {
                HStack {
                    Label("移除后此条目不再生成验证码", systemImage: "minus.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("撤销") {
                        model.recordTOTPRemoveRequested = false
                    }
                }
            } else if model.recordTOTPInput.isEmpty, let existing = model.recordExistingTOTP {
                HStack(spacing: 12) {
                    Image(systemName: "timer.badge.checkmark")
                        .foregroundStyle(AppTheme.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已配置验证码（每 \(existing.period) 秒轮换）")
                            .font(.callout.weight(.medium))
                        Text("出于安全考虑种子不再回显；留空输入框即保持不变。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("移除", role: .destructive) {
                        model.recordTOTPRemoveRequested = true
                    }
                    .accessibilityIdentifier("entry.totpRemove")
                }
            } else {
                HStack(spacing: 12) {
                    TextField("Base32 种子或 otpauth:// 链接", text: $model.recordTOTPInput, axis: .vertical)
                        .font(.system(.callout, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                        .accessibilityIdentifier("entry.totpInput")
                    #if os(iOS)
                    Button {
                        showTOTPScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("扫描二维码")
                    .accessibilityIdentifier("entry.totpScan")
                    .sheet(isPresented: $showTOTPScanner) {
                        TOTPQRScannerView { uri in
                            model.recordTOTPInput = uri
                            showTOTPScanner = false
                        }
                    }
                    #endif
                }

                let trimmedInput = model.recordTOTPInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedInput.isEmpty {
                    Text("粘贴服务的 base32 种子，或完整的 otpauth://totp/… 链接。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let parsed = draftTOTPParsed {
                    Label(totpSummary(parsed), systemImage: "checkmark.shield")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.brand)
                        .accessibilityIdentifier("entry.totpParsed")
                } else {
                    Label("无法识别：需要合法 base32 种子或 otpauth:// 链接", systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("entry.totpInvalid")
                }
            }
        }
        .padding(16)
        .background(AppTheme.controlBackground(colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func totpSummary(_ parsed: TOTPSecret) -> String {
        var parts: [String] = []
        if let issuer = parsed.issuer, !issuer.isEmpty {
            parts.append(issuer)
        }
        if let account = parsed.account, !account.isEmpty {
            parts.append(account)
        }
        parts.append("\(parsed.digits) 位 · \(parsed.period) 秒 · \(parsed.algorithm.rawValue)")
        return parts.joined(separator: " · ")
    }

    // MARK: - Permissions

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("权限")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle(isOn: $model.recordPermissions.readOnly) {
                Text("只读锁定")
                    .font(.callout.weight(.medium))
                Text("锁定后此条目不可编辑或删除，需先在此解锁。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("entry.permissionReadOnly")

            Toggle(isOn: $model.recordPermissions.hideSecret) {
                Text("隐藏密码")
                    .font(.callout.weight(.medium))
                Text("密码可复制使用，但明文永不在界面显示（对应 Bitwarden Hide Passwords）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("entry.permissionHideSecret")

            Toggle(isOn: $model.recordPermissions.requireReauth) {
                Text("生物识别二次确认")
                    .font(.callout.weight(.medium))
                Text("复制密码或验证码前需通过 Touch ID / Face ID / 设备密码。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("entry.permissionReauth")

            VStack(alignment: .leading, spacing: 6) {
                Text("AI 访问")
                    .font(.callout.weight(.medium))
                Picker("AI 访问", selection: $model.recordPermissions.aiAccess) {
                    Text("禁止").tag(AIAccessLevel.none)
                    Text("仅元数据").tag(AIAccessLevel.metadata)
                    Text("元数据 + 工具").tag(AIAccessLevel.metadataAndTools)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("entry.aiAccess")
                Text(aiAccessDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(AppTheme.controlBackground(colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var aiAccessDescription: String {
        switch model.recordPermissions.aiAccess {
        case .none:
            return "MCP agent 完全看不到这条记录（默认）。"
        case .metadata:
            return "agent 可查询此记录的脱敏元数据，不能调用复制工具。"
        case .metadataAndTools:
            return "agent 可查询元数据，并通过剪贴板复制密码/验证码。"
        }
    }

    private var editingContextTags: [String] {
        model.editingSignals
            .filter { $0.category != .secret }
            .sorted { lhs, rhs in
                editingPriority(for: lhs.name) > editingPriority(for: rhs.name)
            }
            .compactMap(renderedSignalTag)
            .prefix(6)
            .map { $0 }
    }

    private func editingPriority(for key: String) -> Int {
        switch key {
        case "url", "endpoint": return 120
        case "host", "brokers": return 110
        case "label", "service": return 100
        case "account", "username": return 90
        case "database", "bucket", "topic", "scope", "project", "vhost": return 80
        case "env", "region", "provider", "engine", "mechanism", "access_key": return 70
        default: return 0
        }
    }

    private func renderedSignalTag(_ signal: VaultSignal) -> String? {
        switch signal.name {
        case "url", "endpoint":
            if let host = URL(string: signal.value)?.host, !host.isEmpty {
                return "url:\(host)"
            }
            return "\(signal.name):\(signal.value)"
        case "service":
            return "label:\(signal.value)"
        case "database":
            return "db:\(signal.value)"
        case "username":
            return "user:\(signal.value)"
        case "access_key":
            return "ak:\(signal.value)"
        default:
            return "\(signal.name):\(signal.value)"
        }
    }
}
