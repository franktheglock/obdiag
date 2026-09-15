import SwiftUI
import Combine
import UIKit

/// One message in the transcript, styled by role.
struct MessageRow: View {
    @Environment(AppEnvironment.self) private var env
    let message: ChatMessage
    var isLastAssistant: Bool = false

    @State private var viewerAttachment: MessageAttachment?

    static func friendlyModelName(_ id: String, settings: AppSettings) -> String {
        if let model = settings.model(withID: id) { return model.name }
        if id == "obdiag/demo" { return "OBDiag Demo" }
        // Local LM Studio ids are often filesystem-ish; keep them short.
        return id.contains("/") ? String(id.split(separator: "/").last ?? "") : id
    }

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            assistantMessage
        case .tool, .system:
            EmptyView()
        }
    }

    // MARK: User

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 44)
            VStack(alignment: .trailing, spacing: 8) {
                if !message.attachments.isEmpty {
                    attachmentGrid
                }
                if !message.text.isBlank {
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Palette.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityLabel(userAccessibilityLabel)
        .sheet(item: $viewerAttachment) { attachment in
            ImageViewerSheet(attachment: attachment)
        }
    }

    private var userAccessibilityLabel: String {
        if message.attachments.isEmpty { return "You said: \(message.text)" }
        let imageLabel = "\(message.attachments.count) image\(message.attachments.count == 1 ? "" : "s") attached"
        return message.text.isBlank ? "You sent \(imageLabel)" : "You said: \(message.text). \(imageLabel)."
    }

    @ViewBuilder
    private var attachmentGrid: some View {
        if message.attachments.count == 1, let attachment = message.attachments.first {
            AttachmentThumbnail(attachment: attachment, width: 240, height: 240 * 0.75) {
                viewerAttachment = attachment
            }
        } else {
            LazyVGrid(columns: [GridItem(.fixed(112), spacing: 6), GridItem(.fixed(112), spacing: 6)], spacing: 6) {
                ForEach(message.attachments) { attachment in
                    AttachmentThumbnail(attachment: attachment, width: 112, height: 112) {
                        viewerAttachment = attachment
                    }
                }
            }
            .frame(maxWidth: 230, alignment: .trailing)
        }
    }

    // MARK: Assistant

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 10) {
            if message.isError {
                errorBody
            } else {
                if let reasoning = message.reasoning, !reasoning.isBlank, env.settings.showReasoning {
                    ReasoningView(text: reasoning, isStreaming: message.isStreaming)
                }

                if !message.toolCalls.isEmpty {
                    ToolActivityView(records: message.toolCalls)
                }

                if message.hasBody {
                    MarkdownText(markdown: message.text)
                        .textSelection(.enabled)
                }

                if message.isStreaming && !message.hasBody && message.toolCalls.isEmpty {
                    TypingIndicator()
                }

                if message.isStopped {
                    Label("Stopped", systemImage: "stop.circle")
                        .font(.obMicro)
                        .foregroundStyle(Palette.textTertiary)
                }

                if !message.citations.isEmpty {
                    CitationsView(citations: message.citations)
                }

                footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var errorBody: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.amber)
            Text(message.text)
                .font(.obCallout)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(13)
        .panel(tint: Palette.amber.opacity(0.10))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let modelID = message.modelID, !modelID.isBlank {
                Text(Self.friendlyModelName(modelID, settings: env.settings))
                    .font(.obMicro)
                    .foregroundStyle(Palette.textTertiary)
            }
            if let usage = message.usage, usage.totalTokens > 0 {
                Text("\(usage.totalTokens) tokens")
                    .font(.obMicro)
                    .foregroundStyle(Palette.textTertiary)
            }
            if !message.isStreaming, message.hasBody {
                Button {
                    UIPasteboard.general.string = message.text
                    Haptics.tap()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.textTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy answer")
            }
            Spacer()
        }
        .padding(.top, 1)
    }
}

// MARK: - Reasoning

struct ReasoningView: View {
    let text: String
    let isStreaming: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "brain.head.profile")
                        .font(.caption.weight(.semibold))
                    Text(isStreaming ? "Thinking…" : "Thought process")
                        .font(.obMicro)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(Palette.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .capsule)

            if isExpanded {
                Text(text)
                    .font(.obCaption)
                    .foregroundStyle(Palette.textSecondary)
                    .italic()
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Palette.strokeStrong)
                            .frame(width: 2)
                    }
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Tool activity

struct ToolActivityView: View {
    let records: [ToolCallRecord]
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(records) { record in
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(.smooth(duration: 0.2)) {
                            if expanded.contains(record.id) {
                                expanded.remove(record.id)
                            } else {
                                expanded.insert(record.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            statusIcon(record)
                            Text(record.displayName)
                                .font(.obMicro)
                                .foregroundStyle(record.status == .failed ? Palette.amber : Palette.textSecondary)
                            if let duration = record.duration {
                                Text(String(format: "%.1fs", duration))
                                    .font(.obMicro)
                                    .foregroundStyle(Palette.textTertiary)
                            }
                            Spacer(minLength: 0)
                            if record.result != nil {
                                Image(systemName: expanded.contains(record.id) ? "chevron.up" : "chevron.down")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Palette.textTertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if expanded.contains(record.id), let result = record.result {
                        Text(prettyResult(result))
                            .obMono(11, weight: .regular)
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(14)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .inputSurface(cornerRadius: 14)
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ record: ToolCallRecord) -> some View {
        switch record.status {
        case .running, .awaitingUser:
            ProgressView()
                .controlSize(.small)
                .tint(Palette.accent)
        case .succeeded:
            Image(systemName: record.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.success)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.amber)
        }
    }

    private func prettyResult(_ raw: String) -> String {
        guard let value = JSONValue.parse(raw) else { return raw.truncated(to: 600) }
        return value.prettyString.truncated(to: 800)
    }
}

// MARK: - Attachments

/// Async-loading attachment thumbnail that never blocks the transcript.
struct AttachmentThumbnail: View {
    let attachment: MessageAttachment
    var width: CGFloat
    var height: CGFloat
    var onTap: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(Color.white.opacity(0.06))
                    Image(systemName: "photo")
                        .font(.body)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            Haptics.tap()
            onTap()
        }
        .task(id: attachment.id) {
            image = AttachmentStore.image(for: attachment)
        }
        .accessibilityLabel("Attached photo, \(attachment.pixelWidth) by \(attachment.pixelHeight)")
        .accessibilityAddTraits(.isButton)
    }
}

/// Full-screen, zoomable attachment viewer.
struct ImageViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: MessageAttachment

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        SheetNavigationStack(backdrop: .solid(.black)) {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { value in
                                    scale = min(max(lastScale * value.magnification, 1), 6)
                                }
                                .onEnded { _ in lastScale = scale }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.smooth) {
                                scale = scale > 1 ? 1 : 2.5
                                lastScale = scale
                            }
                        }
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle("\(attachment.pixelWidth) × \(attachment.pixelHeight)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if let image { UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil) }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Save to photos")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .task(id: attachment.id) {
            image = AttachmentStore.image(for: attachment)
        }
    }
}

// MARK: - Citations

struct CitationsView: View {
    let citations: [Citation]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Sources")
                .font(.obMicro)
                .foregroundStyle(Palette.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(citations) { citation in
                        if let url = citation.urlValue {
                            Link(destination: url) {
                                HStack(spacing: 7) {
                                    AsyncImage(url: url.faviconURL) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Image(systemName: "globe")
                                            .font(.caption2)
                                            .foregroundStyle(Palette.textTertiary)
                                    }
                                    .frame(width: 15, height: 15)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(citation.host)
                                            .font(.obMicro)
                                            .foregroundStyle(Palette.textPrimary)
                                            .lineLimit(1)
                                        Text(citation.title)
                                            .font(.caption2)
                                            .foregroundStyle(Palette.textTertiary)
                                            .lineLimit(1)
                                            .frame(maxWidth: 150, alignment: .leading)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.tint(Palette.accent.opacity(0.10)).interactive(), in: .rect(cornerRadius: 12))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Misc

struct TypingIndicator: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Palette.accent.opacity(phase == index ? 0.95 : 0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 4)
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
        .accessibilityLabel("Assistant is responding")
    }
}

// MARK: - Ask user

/// Multiple-choice question presented when the assistant needs input.
struct AskUserSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let question: AskUserQuestion

    @State private var selected: Set<String> = []
    @State private var freeform = ""

    var body: some View {
        SheetNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: "questionmark.bubble.fill")
                            .font(.title3)
                            .foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            if let header = question.header, !header.isBlank {
                                Text(header)
                                    .font(.obCaption)
                                    .foregroundStyle(Palette.textTertiary)
                            }
                            Text(question.question)
                                .font(.obTitle2)
                                .foregroundStyle(Palette.textPrimary)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel()

                    VStack(spacing: 9) {
                        ForEach(question.options) { option in
                            optionRow(option)
                        }
                    }

                    if question.allowsFreeform {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Or type your answer")
                                .font(.obMicro)
                                .foregroundStyle(Palette.textTertiary)
                            TextField("Your answer…", text: $freeform, axis: .vertical)
                                .lineLimit(2...5)
                                .font(.obCallout)
                                .padding(12)
                                .inputSurface(cornerRadius: 14)
                        }
                    }
                }
                .padding(18)
                .padding(.bottom, 20)
            }
            .transparentSheetContent()
            .navigationTitle("One quick question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Skip") {
                        env.chat.dismissPendingQuestion()
                        dismiss()
                    }
                }
            }
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 6) {
                    GlassActionButton(
                        title: "Send answer",
                        systemImage: "arrow.up",
                        isEnabled: !selected.isEmpty || !freeform.isBlank
                    ) {
                        submit()
                    }
                    Text("Your answer goes straight back to the assistant.")
                        .font(.obMicro)
                        .foregroundStyle(Palette.textTertiary)
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 6)
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }

    private func optionRow(_ option: AskUserQuestion.Option) -> some View {
        let isSelected = selected.contains(option.label)
        return Button {
            Haptics.selection()
            if question.allowsMultiple {
                if isSelected { selected.remove(option.label) } else { selected.insert(option.label) }
            } else {
                selected = [option.label]
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isSelected ? Palette.accent : Palette.textTertiary.opacity(0.6))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(.obCallout.weight(.semibold))
                            .foregroundStyle(Palette.textPrimary)
                            .multilineTextAlignment(.leading)
                        if option.isRecommended {
                            Text("likely")
                                .font(.obMicro)
                                .foregroundStyle(Palette.accent)
                        }
                    }
                    if let detail = option.detail, !detail.isBlank {
                        Text(detail)
                            .font(.obCaption)
                            .foregroundStyle(Palette.textTertiary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel(tint: isSelected ? Palette.accent.opacity(0.12) : nil)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? Palette.accent.opacity(0.5) : Palette.stroke, lineWidth: 1)
        )
    }

    private func submit() {
        var parts = Array(selected).sorted()
        let typed = freeform.trimmed
        if !typed.isEmpty { parts.append(typed) }
        env.chat.answerPendingQuestion(parts.joined(separator: question.allowsMultiple ? ", " : " · "))
        dismiss()
    }
}
