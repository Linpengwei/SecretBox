import SwiftUI

#if os(macOS)
import AppKit
#endif

private enum MenuBarMode: String {
    case capture
    case search
}

struct RecordVaultView: View {
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: SecretBoxAppModel
    let compact: Bool
    @State private var previewFieldsExpanded = false

    // Quick-access (检索) mode state. The mode itself persists across panel
    // openings; UI-test runs pin it via launch environment so the suite stays
    // hermetic against UserDefaults left over from earlier launches.
    @AppStorage("SecretBox.menuBar.mode") private var storedModeRaw = MenuBarMode.capture.rawValue
    @State private var quickQuery = ""
    @State private var selectedResultIndex: Int?
    @State private var hoveredResultIndex: Int?
    @FocusState private var quickSearchFocused: Bool

    var body: some View {
        Group {
            if compact {
                compactCard
            } else {
                expandedCard
            }
        }
    }

    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [
                AppTheme.brand.opacity(0.92),
                AppTheme.brand.opacity(0.72),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                AppTheme.surfaceBackground(colorScheme),
                AppTheme.cardBackground(colorScheme).opacity(0.72),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var panelFill: Color {
        AppTheme.cardBackground(colorScheme)
    }

    private var editorFill: Color {
        AppTheme.surfaceBackground(colorScheme).opacity(0.98)
    }

    private var borderColor: Color {
        AppTheme.border(colorScheme)
    }

    // MARK: - Compact panel

    private var effectiveMode: MenuBarMode {
        if let pinned = model.uiTestMenuBarModePin,
           let mode = MenuBarMode(rawValue: pinned) {
            return mode
        }
        // UI-test runs without an explicit pin always open in capture mode so
        // the existing menu-bar tests are immune to persisted state.
        if model.isUITestRun {
            return .capture
        }
        return MenuBarMode(rawValue: storedModeRaw) ?? .capture
    }

    private var compactCard: some View {
        VStack(spacing: 10) {
            headerRow
            modeToggle

            Group {
                if effectiveMode == .capture {
                    captureSection
                } else {
                    searchSection
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(14)
        .frame(minWidth: 320, maxWidth: 320, minHeight: 460, maxHeight: 560)
        .background(backgroundGradient)
        .overlay(alignment: .bottom) {
            feedbackCapsule
        }
        .animation(.snappy(duration: 0.2), value: model.menuBarFeedback)
    }

    /// Hand-drawn segmented toggle. A native `.segmented` picker renders as a
    /// single-value capsule offscreen (snapshot/docs renders) and reads as a
    /// plain label in stills; plain SwiftUI rows render identically everywhere.
    private var modeToggle: some View {
        HStack(spacing: 2) {
            modeToggleButton("捕获", systemImage: "plus.square.on.square", mode: .capture)
            modeToggleButton("检索", systemImage: "magnifyingglass", mode: .search)
        }
        .padding(3)
        .background(editorFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        }
        .accessibilityIdentifier("menubar.modePicker")
    }

    private func modeToggleButton(_ title: String, systemImage: String, mode: MenuBarMode) -> some View {
        let selected = effectiveMode == mode
        return Button {
            storedModeRaw = mode.rawValue
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? .white : .secondary)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accentGradient)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("menubar.mode.\(mode.rawValue)")
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(accentGradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("SecretBox")
                    .font(.subheadline.weight(.semibold))
                Text("\(model.localRecords.count) 条记录")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                model.openSearchFromMenuBar()
                #if os(macOS)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                #endif
            } label: {
                Image(systemName: "rectangle.expand.vertical")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("打开查询界面")
            .accessibilityIdentifier("menubar.dashboard")
            .background(panelFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var feedbackCapsule: some View {
        if let feedback = model.menuBarFeedback {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.brand)
                Text(feedback)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.thinMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(borderColor, lineWidth: 1)
            }
            .padding(.bottom, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("menubar.feedback")
        }
    }

    // MARK: - Capture mode

    private var captureSection: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        PlainTextEditor(text: $model.pastedText, isFirstResponder: true)
                            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                            .accessibilityIdentifier("menubar.pasteField")

                        if model.pastedText.isEmpty {
                            Text("在此处粘贴")
                                .font(.title3.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.top, 14)
                                .padding(.leading, 14)
                                .allowsHitTesting(false)
                        }
                    }
                    .background(editorFill)

                    if let preview = model.pastedSecretPreview {
                        Divider()

                        ScrollView {
                            previewContent(for: preview)
                        }
                        .frame(maxHeight: 250)
                        .background(panelFill.opacity(0.92))
                        .accessibilityIdentifier("menubar.preview")
                    }
                }
            }

            Divider()

            VStack(spacing: 6) {
                if !model.pastedText.isEmpty && !model.canSavePastedCapture {
                    Text("未检测到密钥或 otpauth:// 链接")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                Button {
                    Task { await model.saveFromPastedText() }
                } label: {
                    Text("保存")
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .disabled(!model.canSavePastedCapture)
                .opacity(model.canSavePastedCapture ? 1 : 0.45)
                .accessibilityIdentifier("menubar.save")
                .background(accentGradient)
                .foregroundStyle(.white)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.top, 8)
        }
        .background {
            // Secondary shortcut: ⌘S saves the capture without moving focus.
            Button("") { Task { await model.saveFromPastedText() } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.canSavePastedCapture)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        }
    }

    private func previewContent(for preview: PastedSecretPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Smart preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(preview.clusterDecision.clusterID.schemaDefinition.title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                if preview.hasSecret {
                    Text("Secret detected")
                        .font(.caption2.weight(.medium))
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
                                .background(editorFill, in: Capsule())
                        }
                    }
                }
            }

            let schemaFields = previewSchemaFields(for: preview)
            if !schemaFields.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Cluster schema")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Spacer()

                        if schemaFields.count > 3 {
                            Button(previewFieldsExpanded ? "Collapse" : "Show all") {
                                previewFieldsExpanded.toggle()
                            }
                            .buttonStyle(.plain)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("menubar.previewFieldsToggle")
                        }
                    }

                    ForEach(previewFields(for: preview)) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.label)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)

                            TextField(field.label, text: model.bindingForPastedField(field))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("menubar.previewField.\(field.key)")
                        }
                    }
                }
            }

            if !preview.highlights.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(preview.highlights, id: \.self) { line in
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Quick access (检索) mode

    private var displayedRecords: [VaultRecord] {
        quickQuery.trimmingCharacters(in: .whitespaces).isEmpty
            ? model.recentQuickAccessRecords
            : model.quickAccessResults(for: quickQuery)
    }

    private var searchSection: some View {
        VStack(spacing: 10) {
            searchField

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if quickQuery.trimmingCharacters(in: .whitespaces).isEmpty
                            && displayedRecords.isEmpty {
                            recentEmptyHint
                        } else if displayedRecords.isEmpty {
                            Text("无匹配记录")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 24)
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("menubar.search.empty")
                        } else {
                            if quickQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                                Text("最近使用")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 4)
                                    .accessibilityIdentifier("menubar.search.recentHeader")
                            }
                            ForEach(Array(displayedRecords.enumerated()), id: \.element.id) { index, record in
                                resultRow(record, index: index)
                                    .id(index)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: selectedResultIndex) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.snappy(duration: 0.15)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .onAppear {
            resetSelection()
            quickSearchFocused = true
        }
        .onChange(of: quickQuery) { _, _ in
            resetSelection()
        }
    }

    private var baseSearchField: some View {
        TextField("搜索 · ↑↓ 选择 · ↩ 复制 · ⌘↩ 打开", text: $quickQuery)
            .textFieldStyle(.roundedBorder)
            .focused($quickSearchFocused)
            .accessibilityIdentifier("menubar.search.field")
    }

    #if os(macOS)
    private var searchField: some View {
        baseSearchField
            .onSubmit { copySelectedPassword() }
            .onKeyPress { handleSearchKeyPress($0) }
    }
    #else
    private var searchField: some View {
        baseSearchField
            .onSubmit { copySelectedPassword() }
    }
    #endif

    private var recentEmptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("暂无最近使用")
                .font(.callout.weight(.medium))
            Text("复制密码或验证码后，记录会出现在这里")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("menubar.search.recentEmpty")
    }

    private func resultRow(_ record: VaultRecord, index: Int) -> some View {
        let isSelected = selectedResultIndex == index
        let showsActions = isSelected || hoveredResultIndex == index
        return Button {
            primaryQuickAction(for: record)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: recordIcon(for: record))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.brand)
                    .frame(width: 26, height: 26)
                    .background(editorFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(record.title)
                            .font(.callout.weight(isSelected ? .semibold : .medium))
                            .lineLimit(1)
                        if record.totp != nil {
                            Image(systemName: "timer")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(rowSubtitle(for: record))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if showsActions {
                    HStack(spacing: 2) {
                        if record.password?.isEmpty == false {
                            rowActionButton("doc.on.doc", help: "复制密码") {
                                Task { await model.quickAccessCopyPassword(for: record) }
                            }
                            .accessibilityIdentifier("menubar.search.row.\(index).copyPassword")
                        }
                        if record.totp != nil {
                            rowActionButton("timer", help: "复制验证码") {
                                Task { await model.quickAccessCopyTOTP(for: record) }
                            }
                            .accessibilityIdentifier("menubar.search.row.\(index).copyTOTP")
                        }
                        if record.effectivePermissions.aiAccess != .none {
                            rowActionButton("sparkles", help: "复制 AI 引用") {
                                model.quickAccessCopyAIReference(for: record)
                            }
                            .accessibilityIdentifier("menubar.search.row.\(index).copyAIReference")
                        }
                        rowActionButton("arrow.up.forward.app", help: "在主窗口打开") {
                            revealInDashboard(record)
                        }
                        .accessibilityIdentifier("menubar.search.row.\(index).openDetail")
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowFill(selected: isSelected, hovered: hoveredResultIndex == index), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("menubar.search.row.\(index)")
        .onHover { hovering in
            hoveredResultIndex = hovering ? index : (hoveredResultIndex == index ? nil : hoveredResultIndex)
        }
    }

    private func rowActionButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
        .background(editorFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func rowFill(selected: Bool, hovered: Bool) -> Color {
        if selected {
            return AppTheme.brand.opacity(0.16)
        }
        if hovered {
            return AppTheme.brand.opacity(0.08)
        }
        return .clear
    }

    private func rowSubtitle(for record: VaultRecord) -> String {
        if let subtitle = record.subtitle, !subtitle.isEmpty {
            return subtitle
        }
        if let username = record.username, !username.isEmpty {
            return username
        }
        for key in ["host", "service", "url", "endpoint", "brokers"] {
            if let value = record.fieldMap[key], !value.isEmpty {
                return value
            }
        }
        return record.recordType
    }

    private func recordIcon(for record: VaultRecord) -> String {
        let type = record.templateType ?? record.itemType
        return SecretBoxAppModel.supportedTypes.first(where: { $0.id == type })?.systemImage ?? "lock.fill"
    }

    // MARK: - Quick access interactions

    private func resetSelection() {
        selectedResultIndex = displayedRecords.isEmpty ? nil : 0
    }

    /// Row tap and plain ↩ both run the record's primary action: copy the
    /// password, or the verification code for authenticator-only items.
    private func primaryQuickAction(for record: VaultRecord) {
        Task {
            if record.password?.isEmpty == false {
                await model.quickAccessCopyPassword(for: record)
            } else {
                await model.quickAccessCopyTOTP(for: record)
            }
        }
    }

    private func copySelectedPassword() {
        guard let index = selectedResultIndex, displayedRecords.indices.contains(index) else { return }
        primaryQuickAction(for: displayedRecords[index])
    }

    private func revealInDashboard(_ record: VaultRecord) {
        model.revealRecordInDashboard(record)
        #if os(macOS)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }

    #if os(macOS)
    /// Keyboard flow inside the search field: ↑/↓ move the selection, ↩ runs
    /// the primary copy action, ⌘↩ reveals the record in the main window,
    /// Esc clears the query.
    private func handleSearchKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .downArrow:
            guard !displayedRecords.isEmpty else { return .ignored }
            let next = min((selectedResultIndex ?? -1) + 1, displayedRecords.count - 1)
            selectedResultIndex = next
            return .handled
        case .upArrow:
            guard !displayedRecords.isEmpty else { return .ignored }
            guard let current = selectedResultIndex else {
                selectedResultIndex = 0
                return .handled
            }
            selectedResultIndex = max(current - 1, 0)
            return .handled
        case .return:
            guard let index = selectedResultIndex, displayedRecords.indices.contains(index) else {
                return .ignored
            }
            let record = displayedRecords[index]
            if press.modifiers.contains(.command) {
                revealInDashboard(record)
            } else {
                primaryQuickAction(for: record)
            }
            return .handled
        case .escape:
            if !quickQuery.isEmpty {
                quickQuery = ""
                return .handled
            }
            return .ignored
        default:
            return .ignored
        }
    }
    #endif

    // MARK: - Expanded (window) card

    private var expandedCard: some View {
        VStack(spacing: 16) {
            Text("Dashboard")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(panelFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    PlainTextEditor(text: $model.pastedText, isFirstResponder: true)
                        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)

                    if model.pastedText.isEmpty {
                        Text("在此处粘贴")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 14)
                            .padding(.leading, 14)
                            .allowsHitTesting(false)
                    }
                }
                .background(editorFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                SecureField("Password", text: $model.recordPassword)
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task { await model.saveFromPastedText() }
                } label: {
                    Text("保存")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .background(accentGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)
            }
            .padding(18)
            .background(panelFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }

            if let record = model.latestSavedRecord {
                HStack {
                    Text(record.title)
                        .font(.headline)
                    Spacer()
                    if let context = record.signals?.first(where: { $0.name == "host" || $0.name == "label" || $0.name == "service" || $0.name == "url" })?.value {
                        Text(context)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(minWidth: 360, minHeight: 520)
        .background(backgroundGradient)
    }

    private func previewFields(for preview: PastedSecretPreview) -> [PastedPreviewField] {
        let fields = previewSchemaFields(for: preview)
        if previewFieldsExpanded || fields.count <= 3 {
            return fields
        }
        return Array(fields.prefix(3))
    }

    private func previewSchemaFields(for preview: PastedSecretPreview) -> [PastedPreviewField] {
        let schema = preview.clusterDecision.clusterID.schemaDefinition
        let fieldByKey = Dictionary(uniqueKeysWithValues: preview.editableFields.map { ($0.key, $0) })

        var ordered: [PastedPreviewField] = []
        for schemaField in schema.fields {
            if let matched = schemaField.keys.compactMap({ fieldByKey[$0] }).first {
                var field = matched
                field.label = schemaField.label
                ordered.append(field)
            }
        }

        let consumed = Set(ordered.map(\.key))
        let remaining = preview.editableFields.filter { !consumed.contains($0.key) }
        return ordered + remaining
    }
}

#if os(macOS)
private struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isFirstResponder: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.string = text
        textView.setAccessibilityIdentifier("menubar.pasteField")

        scrollView.documentView = textView

        if isFirstResponder {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        if isFirstResponder, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}
#else
private struct PlainTextEditor: UIViewRepresentable {
    @Binding var text: String
    var isFirstResponder: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.font = .systemFont(ofSize: UIFont.systemFontSize)
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.text = text
        textView.accessibilityIdentifier = "menubar.pasteField"
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        if isFirstResponder, !uiView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}
#endif
