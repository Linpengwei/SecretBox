import SwiftUI

struct SearchVaultView: View {
    @ObservedObject var model: SecretBoxAppModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isSearchFocused: Bool
    @State private var recordPendingDeletion: VaultRecord?
    @State private var recordPendingAIReference: VaultRecord?

    var body: some View {
        #if os(macOS)
        HSplitView {
            vaultSidebar
                .frame(minWidth: 220, idealWidth: 236, maxWidth: 252)

            itemBrowser
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)

            itemDetail
                .frame(minWidth: 560)
        }
        .background(windowBackground)
        .onChange(of: model.searchFocusToken) { _, _ in
            isSearchFocused = true
        }
        #else
        NavigationStack {
            VStack(spacing: 0) {
                filterChips
                Divider()
                itemBrowser
            }
            .navigationTitle("SecretBox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.beginCreate()
                    } label: {
                        Label("Quick Capture", systemImage: "plus")
                    }
                    .accessibilityIdentifier("dashboard.capture")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.runSmartOrganizationNow() }
                    } label: {
                        Label("AI Organize", systemImage: "wand.and.stars")
                    }
                    .accessibilityIdentifier("toolbar.organize")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.settingsPresented = true
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("toolbar.settings")
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { model.selectedSearchRecord != nil },
                set: { if !$0 { model.selectedSearchRecord = nil } }
            )) {
                itemDetail
                    .navigationTitle(model.selectedSearchRecord?.title ?? "Item")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        // ToolbarItem(placement: .status) does not render on iPhone — surface
        // the model's status line as a floating capsule instead (copy/save
        // confirmations are part of the smoke-test acceptance chain).
        .overlay(alignment: .bottom) {
            Text(model.statusMessage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .clipShape(Capsule())
                .padding(.bottom, 14)
                .frame(maxWidth: 320)
                .allowsHitTesting(false)
                .accessibilityIdentifier("app.status")
                .animation(.easeInOut(duration: 0.2), value: model.statusMessage)
        }
        .onChange(of: model.searchFocusToken) { _, _ in
            isSearchFocused = true
        }
        #endif
    }

    private var windowBackground: some View {
        LinearGradient(
            colors: [
                AppTheme.pageBackground(colorScheme),
                AppTheme.underPageBackground(colorScheme),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SecretBoxAppModel.browserFilters) { filter in
                    Button {
                        model.selectBrowserFilter(filter.id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: filter.systemImage)
                                .font(.caption)
                            Text(filter.title)
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selectionFill(for: filter.id), in: Capsule())
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebar.type.\(filter.id)")
                }

                if !model.clusterBrowserSummaries.isEmpty {
                    Divider()
                        .frame(height: 20)

                    Menu {
                        Picker("Cluster sort", selection: $model.clusterBrowserSortMode) {
                            ForEach(ClusterBrowserSortMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.10), in: Capsule())
                    }
                    .accessibilityIdentifier("sidebar.clusterSortMode")

                    ForEach(model.clusterBrowserSummaries) { cluster in
                        Button {
                            model.browseCluster(model.selectedClusterBrowserID == cluster.id ? nil : cluster.id)
                        } label: {
                            HStack(spacing: 4) {
                                Text(cluster.label)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Text("\(cluster.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(sidebarClusterFill(for: cluster.id), in: Capsule())
                            .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sidebar.cluster.\(cluster.id)")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var vaultSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SecretBox")
                    .font(.title2.weight(.semibold))
                Text("Vault")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(SecretBoxAppModel.browserFilters) { filter in
                        Button {
                            model.selectBrowserFilter(filter.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: filter.systemImage)
                                    .font(.headline)
                                    .frame(width: 30, height: 30)
                                    .background(selectionFill(for: filter.id), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(filter.title)
                                        .font(.body.weight(model.browserFilterID == filter.id ? .semibold : .regular))
                                    if filter.id == "all" {
                                        Text("\(model.searchResults.isEmpty ? (model.latestSavedRecord == nil ? 0 : 1) : model.searchResults.count) total")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(sidebarRowFill(for: filter.id), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sidebar.type.\(filter.id)")
                    }

                    if !model.clusterBrowserSummaries.isEmpty {
                        Divider()
                            .padding(.vertical, 6)

                        HStack(spacing: 8) {
                            Text("Clusters")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("Cluster sort", selection: $model.clusterBrowserSortMode) {
                                ForEach(ClusterBrowserSortMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .accessibilityIdentifier("sidebar.clusterSortMode")
                        }
                        .padding(.horizontal, 12)

                        ForEach(model.clusterBrowserSummaries) { cluster in
                            Button {
                                model.browseCluster(model.selectedClusterBrowserID == cluster.id ? nil : cluster.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(cluster.label)
                                            .font(.caption.weight(model.selectedClusterBrowserID == cluster.id ? .semibold : .medium))
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(cluster.count)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    if let highlight = cluster.highlights.first {
                                        Text(highlight)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(sidebarClusterFill(for: cluster.id), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("sidebar.cluster.\(cluster.id)")
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(sidebarBackground)
    }

    private var sidebarBackground: some View {
        Group {
            if #available(iOS 26.0, macOS 26.0, *) {
                RoundedRectangle(cornerRadius: 0, style: .continuous)
                    .fill(Color.clear)
                    .glassEffect(.regular.tint(.white.opacity(0.18)), in: .rect(cornerRadius: 0))
            } else {
                AppTheme.underPageBackground(colorScheme)
            }
        }
    }

    private func selectionFill(for id: String) -> some ShapeStyle {
        model.browserFilterID == id ? Color.accentColor.opacity(0.22) : Color.black.opacity(0.05)
    }

    private func sidebarRowFill(for id: String) -> some ShapeStyle {
        model.browserFilterID == id ? Color.accentColor.opacity(0.14) : Color.clear
    }

    private func sidebarClusterFill(for id: String) -> some ShapeStyle {
        model.selectedClusterBrowserID == id ? Color.accentColor.opacity(0.12) : Color.clear
    }

    private var itemBrowser: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    TextField("Search vault", text: $model.searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSearchFocused)
                        .accessibilityIdentifier("dashboard.searchField")
                        .onSubmit {
                            Task { await model.searchPasswords() }
                        }

                    Button("Search") {
                        Task { await model.searchPasswords() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("dashboard.searchButton")
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.browserTitle)
                        .font(.title3.weight(.semibold))
                    Text(model.browserSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                tagRow
            }
            .padding(18)

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.filteredResults) { record in
                        Button {
                            model.selectedSearchRecord = record
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.title)
                                            .font(.headline)
                                            .accessibilityIdentifier("results.title.\(record.id)")
                                            .accessibilityLabel(record.title)
                                            .accessibilityValue(record.title)
                                    }
                                    Spacer()
                                }

                                Text(browserDescription(for: record))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)

                                if let contextLine = browserContextLine(for: record) {
                                    Text(contextLine)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(itemRowBackground(isSelected: model.selectedSearchRecord?.id == record.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("results.row.\(record.id)")
                        .accessibilityLabel(model.selectedSearchRecord?.id == record.id ? "selected-result" : "result")
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .background(browserBackground)
    }

    private var browserBackground: some View {
        AppTheme.controlBackground(colorScheme).opacity(0.62)
    }

    private func itemRowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.14) : AppTheme.pageBackground(colorScheme).opacity(0.9))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.black.opacity(isSelected ? 0.10 : 0.05), lineWidth: 1)
            }
    }

    private var itemDetail: some View {
        VStack(spacing: 0) {
            detailHeader
                .padding(.horizontal, 24)
                .padding(.vertical, 18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailCard
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .background(detailBackground)
    }

    private var detailBackground: some View {
        Group {
            if #available(iOS 26.0, macOS 26.0, *) {
                RoundedRectangle(cornerRadius: 0, style: .continuous)
                    .fill(Color.clear)
                    .glassEffect(.regular.tint(.white.opacity(0.15)), in: .rect(cornerRadius: 0))
            } else {
                AppTheme.pageBackground(colorScheme)
            }
        }
    }

    private var detailHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Captured Details")
                    .font(.title3.weight(.semibold))
                Text("Structured view from clustered signals")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            detailActions
        }
    }

    private var detailActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                quickCaptureButton
                editButton
                copyPasswordButton
                copyAIRefButton
            }

            VStack(alignment: .trailing, spacing: 8) {
                quickCaptureButton
                HStack(spacing: 10) {
                    editButton
                    copyPasswordButton
                    copyAIRefButton
                }
            }

            VStack(alignment: .trailing, spacing: 8) {
                quickCaptureButton
                editButton
                copyPasswordButton
                copyAIRefButton
            }
        }
    }

    private var quickCaptureButton: some View {
        Button("Quick Capture") {
            model.beginCreate()
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("dashboard.capture")
    }

    @ViewBuilder
    private var editButton: some View {
        if let selectedRecord = model.selectedSearchRecord ?? model.filteredResults.first {
            Button("Edit") {
                model.beginEditing(selectedRecord)
            }
            .buttonStyle(.bordered)
            .disabled(selectedRecord.effectivePermissions.readOnly)
            .accessibilityIdentifier("detail.edit")
        }
    }

    @ViewBuilder
    private var copyPasswordButton: some View {
        if let record = model.selectedSearchRecord, let password = record.password {
            Button("Copy Password") {
                Task {
                    guard await model.requestSecretUse(for: record, action: "copy the password") else { return }
                    model.copyPassword(password)
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("detail.copyPassword")
        }
    }

    /// Copies a redacted `<secretbox-credential>` reference (record id +
    /// metadata, never the plaintext) for pasting into an AI agent chat; the
    /// agent resolves it through the SecretBox MCP server. Records that are
    /// not yet AI-readable get a confirmation dialog first — pasting a
    /// reference the agent cannot see would silently fail.
    @ViewBuilder
    private var copyAIRefButton: some View {
        if let record = model.selectedSearchRecord ?? model.filteredResults.first, record.password != nil {
            Button("复制 AI 引用") {
                if record.effectivePermissions.aiAccess != .none {
                    model.copyAIReference(for: record)
                } else {
                    recordPendingAIReference = record
                }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("detail.copyAIRef")
            .confirmationDialog(
                "这条记录还没有开放给 AI",
                isPresented: Binding(
                    get: { recordPendingAIReference?.id == record.id },
                    set: { if !$0 { recordPendingAIReference = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("开放 AI 访问并复制引用") {
                    model.setAIReadable(id: record.id, allowed: true)
                    model.copyAIReference(for: record)
                    recordPendingAIReference = nil
                }
                Button("Cancel", role: .cancel) {
                    recordPendingAIReference = nil
                }
            } message: {
                Text("未开放给 AI 的记录对 MCP agent 完全不可见，粘贴的引用将无法被解析。开放后 agent 可凭 record_id 直接取用，明文不会进入对话。")
            }
        }
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let record = model.selectedSearchRecord ?? model.filteredResults.first {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.title)
                            .font(.largeTitle.weight(.semibold))
                            .accessibilityIdentifier("detail.title")
                            .accessibilityLabel(record.title)
                            .accessibilityValue(record.title)
                    }
                    Spacer()
                    if let reason = record.matchReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(detailDescription(for: record))
                    .font(.body)

                if let clusterLabel = record.clusterLabel, !clusterLabel.isEmpty {
                    Text("Organized as \(clusterLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("detail.clusterLabel")
                }

                Text(record.title)
                    .font(.caption2)
                    .foregroundStyle(.clear)
                    .accessibilityIdentifier("detail.titleValue")
                    .accessibilityLabel(record.title)
                    .accessibilityValue(record.title)

                let tags = displayTags(for: record)
                if !tags.isEmpty {
                    FlowTagRow(tags: tags)
                }

                Divider()

                let clusterRows = clusterSchemaRows(for: record)
                if !clusterRows.isEmpty {
                    itemSection(title: "Cluster Schema") {
                        ForEach(clusterRows, id: \.key) { row in
                            detailRow(row.label, row.value)
                        }
                    }
                }

                let contextRows = signalRows(for: record)
                if !contextRows.isEmpty {
                    itemSection(title: "Detected Context") {
                        ForEach(contextRows, id: \.key) { row in
                            detailRow(row.label, row.value)
                        }
                    }
                }

                itemSection(title: "Identity") {
                    if let username = record.username, !username.isEmpty {
                        detailRow("Username", username)
                    } else if let account = preferredValue(for: record, names: ["account"]) {
                        detailRow("Account", account)
                    } else {
                        detailRow("Principal", "Not set")
                    }
                }

                ForEach(record.groupedFields, id: \.title) { group in
                    itemSection(title: group.title) {
                        ForEach(group.fields) { field in
                            if !field.value.isEmpty, field.key != "username", !detailSuppressedFieldKeys.contains(field.key) {
                                detailRow(field.label, field.value, monospaced: field.hidden)
                            }
                        }
                    }
                }

                if let password = record.password {
                    itemSection(title: "Secret") {
                        if record.effectivePermissions.hideSecret {
                            HStack(alignment: .firstTextBaseline) {
                                detailRow("Password", String(repeating: "•", count: 12), monospaced: true)
                                Text("已隐藏 · 可复制使用，明文不可见")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            detailRow("Password", password, monospaced: true)
                        }
                    }
                }

                if let totp = record.totp {
                    itemSection(title: "两步验证 (Verification Code)") {
                        TOTPLiveCodeSection(
                            secret: totp,
                            masked: record.effectivePermissions.hideSecret
                        ) { code in
                            Task {
                                guard await model.requestSecretUse(for: record, action: "copy the verification code") else { return }
                                model.copyTOTPCode(code)
                            }
                        }
                    }
                }

                itemSection(title: "AI Access") {
                    let aiLevel = record.effectivePermissions.aiAccess
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(aiAccessTitle(aiLevel))
                                .font(.callout.weight(.medium))
                            Text(aiAccessDetail(aiLevel))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("禁止") {
                                model.setAIAccess(id: record.id, level: .none)
                            }
                            Button("仅元数据") {
                                model.setAIAccess(id: record.id, level: .metadata)
                            }
                            Button("元数据 + 工具") {
                                model.setAIAccess(id: record.id, level: .metadataAndTools)
                            }
                        } label: {
                            Text(aiAccessShortLabel(aiLevel))
                        }
                        .fixedSize()
                        .accessibilityIdentifier("detail.aiToggle")
                    }
                }

                if record.effectivePermissions.readOnly || record.effectivePermissions.hideSecret || record.effectivePermissions.requireReauth {
                    Label(permissionBadgeText(record), systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Button("Delete Record", role: .destructive) {
                    recordPendingDeletion = record
                }
                .disabled(record.effectivePermissions.readOnly)
                .accessibilityIdentifier("detail.delete")
                .confirmationDialog(
                    "Delete “\(record.name)”?",
                    isPresented: Binding(
                        get: { recordPendingDeletion != nil },
                        set: { if !$0 { recordPendingDeletion = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        if let id = recordPendingDeletion?.id {
                            model.deleteRecord(id: id)
                        }
                        recordPendingDeletion = nil
                    }
                    Button("Cancel", role: .cancel) {
                        recordPendingDeletion = nil
                    }
                } message: {
                    Text("This removes the record from this Mac. Records already saved on a server are not affected in this beta.")
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No item selected")
                        .font(.title3.weight(.semibold))
                    Text("Pick an item from the browser, or create a new one from the detail header.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(detailSectionBackground)
    }

    private var detailSectionBackground: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(AppTheme.controlBackground(colorScheme).opacity(0.84))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            }
    }

    private var tagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.displayedTags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AppTheme.pageBackground(colorScheme).opacity(0.95), in: Capsule())
                }
            }
        }
        .frame(height: 32)
    }

    private func itemSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func detailRow(_ key: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(key)
                .font(.caption.weight(.semibold))
                .frame(width: 100, alignment: .leading)
                .foregroundStyle(.secondary)
            if monospaced {
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }

    private var detailSuppressedFieldKeys: Set<String> {
        ["label", "service", "env", "region", "provider", "scope", "project", "account", "topic", "bucket", "database", "host", "url", "endpoint", "brokers", "mechanism", "access_key", "vhost"]
    }

    private func aiAccessTitle(_ level: AIAccessLevel) -> String {
        switch level {
        case .none: return "未开放给 AI"
        case .metadata: return "仅元数据开放"
        case .metadataAndTools: return "开放给 AI 读取"
        }
    }

    private func aiAccessDetail(_ level: AIAccessLevel) -> String {
        switch level {
        case .none: return "MCP agent 完全看不到这条记录。"
        case .metadata: return "agent 可查询脱敏元数据，不能调用复制工具。"
        case .metadataAndTools: return "agent 可查询元数据，并通过剪贴板复制密码/验证码。"
        }
    }

    private func aiAccessShortLabel(_ level: AIAccessLevel) -> String {
        switch level {
        case .none: return "禁止"
        case .metadata: return "仅元数据"
        case .metadataAndTools: return "元数据 + 工具"
        }
    }

    private func permissionBadgeText(_ record: VaultRecord) -> String {
        var badges: [String] = []
        let permissions = record.effectivePermissions
        if permissions.readOnly { badges.append("只读锁定") }
        if permissions.hideSecret { badges.append("密码已隐藏") }
        if permissions.requireReauth { badges.append("使用前需二次确认") }
        return badges.joined(separator: " · ")
    }

    private func browserDescription(for record: VaultRecord) -> String {
        if let summary = browserSchemaSummary(for: record) {
            return summary
        }
        if let summary = signalSummary(for: record) {
            return summary
        }
        return record.description
    }

    private func detailDescription(for record: VaultRecord) -> String {
        if let summary = signalSummary(for: record) {
            return summary
        }
        return record.description
    }

    private func signalSummary(for record: VaultRecord) -> String? {
        let parts = [
            preferredValue(for: record, names: ["label", "service"]),
            preferredValue(for: record, names: ["host", "url", "endpoint", "brokers"]),
            preferredValue(for: record, names: ["database", "bucket", "topic", "scope", "vhost"]),
            preferredValue(for: record, names: ["env"])
        ].compactMap { $0 }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " / ")
    }

    private func browserContextLine(for record: VaultRecord) -> String? {
        var parts: [String] = []
        if let clusterLabel = record.clusterLabel, !clusterLabel.isEmpty {
            parts.append(clusterLabel)
        }
        parts.append(contentsOf: displayTags(for: record).prefix(3))
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    private func browserSchemaSummary(for record: VaultRecord) -> String? {
        let schema = record.clusterSchemaDefinition
        let summaryParts = schema.fields.compactMap { field -> String? in
            guard let value = preferredValue(for: record, names: field.keys), !value.isEmpty else { return nil }
            return "\(field.label): \(value)"
        }

        guard !summaryParts.isEmpty else { return nil }
        return Array(summaryParts.prefix(3)).joined(separator: "  ·  ")
    }

    private func clusterSchemaRows(for record: VaultRecord) -> [(key: String, label: String, value: String)] {
        var rows: [(key: String, label: String, value: String)] = []
        if let clusterLabel = record.clusterLabel, !clusterLabel.isEmpty {
            rows.append(("cluster", "Cluster", clusterLabel))
        }
        if let confidence = record.clusterConfidence {
            rows.append(("confidence", "Confidence", "\(Int(confidence * 100))%"))
        }

        let schema = record.clusterSchemaDefinition
        for field in schema.fields {
            if let value = preferredValue(for: record, names: field.keys) {
                rows.append((field.keys.first ?? field.label.lowercased(), field.label, value))
            }
        }
        return rows
    }

    private func displayTags(for record: VaultRecord) -> [String] {
        if let signals = record.signals, !signals.isEmpty {
            return Array(prioritizedSignals(for: signals).compactMap(renderedSignalTag).prefix(4))
        }
        return Array(record.tags.prefix(4))
    }

    private func signalRows(for record: VaultRecord) -> [(key: String, label: String, value: String)] {
        let orderedKeys = ["label", "service", "url", "endpoint", "host", "brokers", "database", "bucket", "topic", "scope", "env", "region", "provider"]
        return orderedKeys.compactMap { key in
            guard let value = preferredValue(for: record, names: [key]), !value.isEmpty else { return nil }
            return (key, humanized(key), value)
        }
    }

    private func preferredValue(for record: VaultRecord, names: [String]) -> String? {
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

    private func prioritizedSignals(for signals: [VaultSignal]) -> [VaultSignal] {
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

    private func humanized(_ key: String) -> String {
        key
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}

private struct FlowTagRow: View {
    let tags: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
        }
    }
}

/// Production wrapper: ticks once per second and renders the deterministic
/// single-frame `TOTPCodeView` with the timeline's date. A `referenceDate`
/// pins a single frame (SwiftUI previews, snapshot baselines).
struct TOTPLiveCodeSection: View {
    let secret: TOTPSecret
    var masked: Bool = false
    var referenceDate: Date? = nil
    var onCopy: (String) -> Void

    var body: some View {
        if let referenceDate {
            TOTPCodeView(secret: secret, date: referenceDate, masked: masked, onCopy: onCopy)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                TOTPCodeView(secret: secret, date: context.date, masked: masked, onCopy: onCopy)
            }
        }
    }
}

/// Bitwarden-style live verification code: the current digits plus a
/// countdown ring that doubles as the copy button. Renders a single
/// deterministic frame for a given `date` — snapshot tests pass a fixed one.
struct TOTPCodeView: View {
    let secret: TOTPSecret
    let date: Date
    var masked: Bool = false
    var onCopy: (String) -> Void

    var body: some View {
        let code = TOTPEngine.code(for: secret, at: date) ?? String(repeating: "–", count: secret.digits)
        let remaining = TOTPEngine.secondsRemaining(period: secret.period, at: date)
        let progress = Double(remaining) / Double(max(1, secret.period))
        let urgent = remaining <= 5

        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(formattedCode(code))
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .kerning(3)
                    .foregroundStyle(masked ? Color.secondary : Color.primary)
                    .accessibilityIdentifier("detail.totpCode")
                Text(codeSubtitle(remaining: remaining))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onCopy(code)
            } label: {
                ZStack {
                    Circle()
                        .trim(from: 0, to: CGFloat(progress))
                        .stroke(urgent ? Color.red : AppTheme.brand,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("复制验证码")
            .accessibilityIdentifier("detail.totpCopy")
        }
        .animation(.linear(duration: 1), value: remaining)
    }

    /// "123 456" — split the digits in the middle for readability.
    private func formattedCode(_ code: String) -> String {
        guard !masked else { return String(repeating: "•", count: code.count) }
        guard code.count > 3 else { return code }
        let midpoint = code.count / 2 + code.count % 2
        return "\(code.prefix(midpoint)) \(code.suffix(code.count - midpoint))"
    }

    private func codeSubtitle(remaining: Int) -> String {
        var parts: [String] = []
        if let issuer = secret.issuer, !issuer.isEmpty { parts.append(issuer) }
        if let account = secret.account, !account.isEmpty { parts.append(account) }
        parts.append("\(remaining) 秒后刷新")
        return parts.joined(separator: " · ")
    }
}
