import SwiftUI

#if os(macOS)
import AppKit
#endif

struct RecordVaultView: View {
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: SecretBoxAppModel
    let compact: Bool
    @State private var previewFieldsExpanded = false

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

    private var compactCard: some View {
        VStack(spacing: 12) {
            Button {
                model.openSearchFromMenuBar()
                #if os(macOS)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                #endif
            } label: {
                VStack(spacing: 4) {
                    Text("Dashboard")
                        .font(.title3.weight(.semibold))
                    Text("打开查询界面")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menubar.dashboard")
            .background(panelFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        ZStack(alignment: .topLeading) {
                            PlainTextEditor(text: $model.pastedText, isFirstResponder: true)
                                .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
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
                            .background(panelFill.opacity(0.92))
                            .accessibilityIdentifier("menubar.preview")
                        }
                    }
                }

                Divider()

                Button {
                    Task { await model.saveFromPastedText() }
                } label: {
                    Text("保存")
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("menubar.save")
                .background(accentGradient)
                .foregroundStyle(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
        }
        .padding(14)
        .frame(width: 290, height: 520)
        .background(backgroundGradient)
    }

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
