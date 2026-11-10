import AppKit
import AppLocalization
import ChatCore
import SwiftUI

private typealias StoredState<Value> = SwiftUI.State<Value>

@MainActor
public struct MessageRow: View {
    @ChatLocalization private var localization
    @ChatAppearance private var appearance
    public let message: ChatMessage

    public init(message: ChatMessage) { self.message = message }

    public var body: some View {
        MessageColumnLayout(isUser: message.role == .user) {
            VStack(alignment: .leading, spacing: ChatTheme.Spacing.medium) {
                Label(roleTitle, systemImage: roleSymbol)
                    .font(ChatTheme.Typography.secondary.weight(.semibold))
                    .foregroundStyle(appearance.palette.secondaryText.color)
                    .accessibilityIdentifier("message.\(message.id.rawValue).role")
                VStack(alignment: .leading, spacing: ChatTheme.Spacing.large) {
                    if message.content.isEmpty {
                        Text(message.status == .streaming ? localization.chat("Waiting for response…") : localization.chat("Empty message"))
                            .foregroundStyle(appearance.palette.mutedText.color)
                    } else {
                        ForEach(Array(MessageBlock.parse(message.content).enumerated()), id: \.offset) { _, block in
                            blockView(block)
                        }
                    }
                }
                .font(ChatTheme.Typography.body)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("message.\(message.id.rawValue).body")
                HStack(spacing: ChatTheme.Spacing.small) {
                    if let status = statusLabel {
                        Label(status.title, systemImage: status.symbol)
                            .font(ChatTheme.Typography.caption)
                            .foregroundStyle(message.status == .failed ? appearance.palette.error.color : appearance.palette.mutedText.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    CopyTextButton(text: message.content, label: localization.chat("Copy message"))
                }
                .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("message.\(message.id.rawValue).metadata")
            }
            .padding(ChatTheme.Spacing.large)
            .foregroundStyle(appearance.palette.primaryText.color)
            .background(message.role == .user ? appearance.palette.userBubble.color : .clear,
                        in: RoundedRectangle(cornerRadius: ChatTheme.Radii.message))
            .accessibilityElement(children: .contain)
        }
        .padding(.vertical, ChatTheme.Spacing.small)
        .environment(\.openURL, OpenURLAction { url in
            MessageLinkPolicy.allows(url) ? .systemAction : .discarded
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.chat("{role} message", ["role": .string(roleTitle)]))
        .accessibilityIdentifier("message.\(message.id.rawValue)")
    }

    @ViewBuilder private func blockView(_ block: MessageBlock) -> some View {
        switch block {
        case .paragraph(let text): inline(text).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            inline(text).font(level <= 2 ? ChatTheme.Typography.title : ChatTheme.Typography.heading)
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
        case .quote(let text):
            HStack(alignment: .top, spacing: ChatTheme.Spacing.medium) {
                RoundedRectangle(cornerRadius: 2).fill(appearance.palette.accent.color.opacity(0.65)).frame(width: 3)
                inline(text).foregroundStyle(appearance.palette.secondaryText.color).fixedSize(horizontal: false, vertical: true)
            }.fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(appearance.palette.mutedText.color)
                inline(text).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .code(let language, let text): CodeBlockView(language: language, text: text)
        case .divider: Rectangle().fill(appearance.palette.stroke.color.opacity(0.45)).frame(height: appearance.strokeWidth)
        }
    }

    private func inline(_ source: String) -> Text {
        var parsed = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
        for run in parsed.runs where run.link != nil {
            parsed[run.range].foregroundColor = appearance.palette.accent.color
        }
        return Text(parsed)
    }

    private var roleTitle: String {
        localization.role(message.role, userIsYou: true)
    }
    private var roleSymbol: String {
        switch message.role {
        case .user: "person.crop.circle"
        case .assistant: "sparkle"
        case .system: "gearshape"
        case .tool: "wrench.and.screwdriver"
        }
    }
    private var statusLabel: (title: String, symbol: String)? {
        switch message.status {
        case .complete: nil
        case .streaming: (localization.chat("Responding…"), "ellipsis")
        case .stopped: (localization.chat("Response stopped"), "stop.circle")
        case .failed: (localization.chat("Response failed"), "exclamationmark.triangle")
        }
    }
}

/// The transcript owns the outer reading column. Rows preserve its full width while placing
/// user bubbles against its trailing edge and assistant content against its leading edge.
struct MessageColumnLayout: Layout {
    let isUser: Bool

    private func columnWidth(_ width: CGFloat) -> CGFloat {
        min(width, ChatTheme.Dimensions.readableWidth) * (isUser ? 0.82 : 1)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, proposal.width ?? ChatTheme.Dimensions.readableWidth)
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: columnWidth(width), height: nil)) ?? .zero
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = columnWidth(bounds.width)
        subviews.first?.place(at: CGPoint(x: isUser ? bounds.maxX - width : bounds.minX, y: bounds.minY),
                             anchor: .topLeading, proposal: ProposedViewSize(width: width, height: nil))
    }
}

@MainActor
private struct CodeBlockView: View {
    @ChatLocalization private var localization
    @ChatAppearance private var appearance
    let language: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? localization.chat("Code")).font(ChatTheme.Typography.caption.monospaced()).lineLimit(1)
                Spacer(minLength: 8)
                CopyTextButton(text: text, label: localization.chat("Copy code"))
            }
            .foregroundStyle(appearance.palette.secondaryText.color)
            .padding(.horizontal, ChatTheme.Spacing.medium)
            .padding(.vertical, ChatTheme.Spacing.xSmall)
            .background(appearance.palette.raised.color)
            Rectangle().fill(appearance.palette.stroke.color.opacity(0.45)).frame(height: appearance.strokeWidth)
            ScrollView(.horizontal) {
                Text(verbatim: text).font(ChatTheme.Typography.code)
                    .foregroundStyle(appearance.palette.primaryText.color)
                    .lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(ChatTheme.Spacing.large)
            }
            .accessibilityLabel(localization.chat("{language} code block, horizontally scrollable", ["language": .string(language ?? localization.chat("Code"))]))
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(appearance.palette.code.color)
        .overlay(RoundedRectangle(cornerRadius: ChatTheme.Radii.code)
            .strokeBorder(appearance.palette.stroke.color.opacity(0.45), lineWidth: appearance.strokeWidth))
        .clipShape(RoundedRectangle(cornerRadius: ChatTheme.Radii.code))
    }
}

@MainActor
struct CopyTextButton: View {
    @ChatLocalization private var localization
    @ChatAppearance private var appearance
    let text: String
    let label: String
    private let pasteboard: NSPasteboard
    @StoredState private var copied = false

    init(text: String, label: String, pasteboard: NSPasteboard = .general) {
        self.text = text
        self.label = label
        self.pasteboard = pasteboard
    }

    var body: some View {
        Button {
            pasteboard.clearContents()
            copied = pasteboard.setString(text, forType: .string)
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                 userInfo: [.announcement: copied ? localization.chat("Copied to clipboard") : localization.chat("Copy failed"),
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        } label: { Label(copied ? localization.chat("Copied") : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.iconOnly)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .font(ChatTheme.Typography.secondary)
        .foregroundStyle(appearance.palette.secondaryText.color)
        .accessibilityLabel(copied ? localization.chat("Copied to clipboard") : label)
        .help(copied ? localization.chat("Copied") : label)
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)); copied = false } catch {}
        }
    }
}
