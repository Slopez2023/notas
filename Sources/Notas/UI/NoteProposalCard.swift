import SwiftUI

struct NoteProposalCard: View {
    let proposal: AssistantProposal
    let style: ResolvedStyle
    let readOnly: Bool
    let busy: Bool
    let accept: () -> Void
    let acceptOne: (Int) -> Void
    let skip: (Int) -> Void
    let keepOriginal: () -> Void
    @State private var mode = PreviewMode.changes
    @State private var expanded = 0

    private enum PreviewMode: String, CaseIterable {
        case changes = "Changes", proposed = "Proposed", original = "Original"
    }

    private var removedColor: Color { style.theme.isDark ? Color(hex: 0xFFB7AD) : Color(hex: 0x87382F) }
    private var addedColor: Color { style.theme.isDark ? Color(hex: 0xA8DDA7) : Color(hex: 0x28602C) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: proposal.state == .applied ? "checkmark.circle" : "text.badge.checkmark")
                Text(proposal.state == .applied ? "Changes accepted" : proposal.state == .dismissed ? "Original kept" : "Review changes")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if proposal.state == .pending {
                    Text("\(proposal.operations.count) \(proposal.operations.count == 1 ? "change" : "changes")")
                        .font(.system(size: 10)).foregroundStyle(style.secondary)
                }
            }
            if !proposal.operations.isEmpty {
                Picker("Preview", selection: $mode) {
                    ForEach(PreviewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).controlSize(.small).labelsHidden()
                    .accessibilityLabel("Edit preview")
                if mode == .changes {
                    HStack(spacing: 12) {
                        Text("Removed").strikethrough().foregroundStyle(removedColor)
                        Text("Added").underline().foregroundStyle(addedColor)
                    }.font(.system(size: 10))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Removed text is struck through. Added text is underlined.")
                }
                if reviewsOneAtATime {
                    ForEach(Array(proposal.operations.enumerated()), id: \.offset) { index, operation in
                        if index == focused {
                            preview(operation, index: index)
                            HStack(spacing: 12) {
                                Button("Accept this change") { acceptOne(index) }
                                    .buttonStyle(.borderedProminent).disabled(busy)
                                Button("Skip") { skip(index) }
                                    .buttonStyle(.borderless).disabled(busy)
                            }.controlSize(.small)
                        } else {
                            collapsedRow(operation, index: index)
                        }
                    }
                } else {
                    ForEach(Array(proposal.operations.enumerated()), id: \.offset) { index, operation in
                        if index > 0 { Divider().opacity(0.4) }
                        preview(operation, index: index)
                    }
                }
            }
            if proposal.state == .pending && !readOnly {
                HStack(spacing: 12) {
                    if proposal.operations.count > 1 {
                        Button("Accept all \(proposal.operations.count) changes", action: accept)
                            .buttonStyle(.bordered).disabled(busy)
                    } else {
                        Button("Accept change", action: accept)
                            .buttonStyle(.borderedProminent).disabled(busy)
                    }
                    Button("Keep original", action: keepOriginal)
                        .buttonStyle(.borderless).disabled(busy)
                }.controlSize(.small)
                Text("Your note stays as it is until you accept.")
                    .font(.system(size: 10)).foregroundStyle(style.secondary)
            } else if proposal.state == .applied {
                Text("Accepted. Press ⌘Z in the note to undo the last change.")
                    .font(.system(size: 10)).foregroundStyle(style.secondary)
            }
            if proposal.removesFormatting == nil, proposal.operations.contains(where: { $0.action == .replace }), proposal.state == .pending {
                Text("Rewritten paragraphs use plain text.")
                    .font(.system(size: 10)).foregroundStyle(style.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(style.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(style.accentColor.opacity(0.25), lineWidth: 0.7))
        .tint(style.accentColor)
        .onChange(of: proposal.operations.count) {
            if expanded >= proposal.operations.count { expanded = max(proposal.operations.count - 1, 0) }
        }
    }

    private var reviewsOneAtATime: Bool {
        proposal.state == .pending && !readOnly && proposal.operations.count > 1
    }

    private var focused: Int { min(expanded, max(proposal.operations.count - 1, 0)) }

    private func collapsedRow(_ operation: AssistantOperation, index: Int) -> some View {
        let original = proposal.before.indices.contains(index) ? proposal.before[index] : ""
        let location = proposal.locations.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            ?? NoteEditPreview.fallbackLocation(of: operation, original: original)
        let name = NoteEditPreview.name(of: BlockKind(rawValue: operation.kind) ?? .body)
        let title = "\(operation.action == .insertAfter ? "Add" : operation.action == .delete ? "Remove" : "Edit") \(name)"
        return Button { expanded = index } label: {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(style.text)
                Spacer(minLength: 8)
                Text(location).font(.system(size: 11)).foregroundStyle(style.secondary).lineLimit(1)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(location)")
    }

    private func preview(_ operation: AssistantOperation, index: Int) -> some View {
        let original = proposal.before.indices.contains(index) ? proposal.before[index] : ""
        let before = operation.action == .insertAfter ? "" : original
        let after = operation.action == .delete ? "" : operation.text
        let location = proposal.locations.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            ?? NoteEditPreview.fallbackLocation(of: operation, original: original)
        let difference = EditDifference.between(before, after)
        let name = NoteEditPreview.name(of: BlockKind(rawValue: operation.kind) ?? .body)
        return VStack(alignment: .leading, spacing: 7) {
            Text("\(operation.action == .insertAfter ? "Add" : operation.action == .delete ? "Remove" : "Edit") \(name)")
                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(style.text)
            Text(location).font(.system(size: 10.5, weight: .medium)).foregroundStyle(style.secondary)
            if mode == .changes {
                if operation.action != .insertAfter {
                    Text("Before").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(style.secondary)
                    Text(before.isEmpty ? AttributedString("Empty \(name)") : markedDifference(difference, showingOriginal: true))
                        .accessibilityLabel("Original: \(before.isEmpty ? "Empty \(name)" : before)")
                }
                if operation.action != .delete {
                    Text("After").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(style.secondary)
                    Text(after.isEmpty ? AttributedString("Empty \(name)") : markedDifference(difference, showingOriginal: false))
                        .accessibilityLabel("Proposed: \(after.isEmpty ? "Empty \(name)" : after)")
                }
            } else {
                let text = mode == .original ? before : after
                let emptyText = mode == .original
                    ? (operation.action == .insertAfter ? "Nothing removed. This is new text." : "Empty \(name).")
                    : (operation.action == .delete ? "\(name.capitalized) will be removed." : "Empty \(name).")
                Text(text.isEmpty ? emptyText : text)
                    .foregroundStyle(text.isEmpty ? style.secondary : style.text)
            }
            if proposal.state == .pending, proposal.removesFormatting?.indices.contains(index) == true,
               proposal.removesFormatting?[index] == true {
                Label("Inline formatting will be removed.", systemImage: "textformat")
                    .font(.system(size: 10)).foregroundStyle(style.secondary)
            }
        }
        .font(.system(size: 12.5)).lineSpacing(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func markedDifference(_ difference: [EditDifference], showingOriginal: Bool) -> AttributedString {
        var result = AttributedString()
        for part in difference where part.kind != (showingOriginal ? .added : .removed) {
            var text = AttributedString(part.text)
            switch part.kind {
            case .unchanged: text.foregroundColor = style.text
            case .removed:
                text.foregroundColor = removedColor
                text.backgroundColor = removedColor.opacity(0.10)
                text.strikethroughStyle = .single
            case .added:
                text.foregroundColor = addedColor
                text.backgroundColor = addedColor.opacity(0.12)
                text.underlineStyle = .single
            }
            result.append(text)
        }
        return result
    }
}
