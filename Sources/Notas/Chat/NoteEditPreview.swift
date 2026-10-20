import Foundation

struct EditDifference: Equatable {
    enum Kind { case unchanged, removed, added }
    let kind: Kind
    var text: String

    static func between(_ original: String, _ proposed: String) -> [EditDifference] {
        guard original != proposed else { return original.isEmpty ? [] : [EditDifference(kind: .unchanged, text: original)] }
        let old = tokens(original), new = tokens(proposed)
        // Bound the work for long paragraphs or complete rewrites.
        guard old.count <= 1_000, new.count <= 1_000, old.count * new.count <= 160_000 else {
            return surroundingDifference(original, proposed)
        }
        let difference = new.difference(from: old)
        var removals = Set<Int>(), additions = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): additions.insert(offset)
            }
        }
        var result: [EditDifference] = [], i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removals.contains(i) {
                append(.removed, old[i], to: &result); i += 1
            } else if j < new.count, additions.contains(j) {
                append(.added, new[j], to: &result); j += 1
            } else {
                append(.unchanged, new[j], to: &result); i += 1; j += 1
            }
        }
        return groupedChanges(result)
    }

    private static func groupedChanges(_ parts: [EditDifference]) -> [EditDifference] {
        var result: [EditDifference] = [], removed = "", added = ""
        func flush() {
            append(.removed, removed, to: &result)
            append(.added, added, to: &result)
            removed = ""; added = ""
        }
        for (index, part) in parts.enumerated() {
            switch part.kind {
            case .removed: removed += part.text
            case .added: added += part.text
            case .unchanged:
                if (!removed.isEmpty || !added.isEmpty), part.text.allSatisfy(\.isWhitespace),
                   index + 1 < parts.count, parts[index + 1].kind != .unchanged {
                    removed += part.text; added += part.text
                } else {
                    flush()
                    append(.unchanged, part.text, to: &result)
                }
            }
        }
        flush()
        return result
    }

    private static func tokens(_ text: String) -> [String] {
        var result: [String] = [], current = "", previous = -1
        for character in text {
            let category = character.isWhitespace ? 0 : (character.isLetter || character.isNumber ? 1 : 2)
            if category != previous || category == 2 {
                if !current.isEmpty { result.append(current) }
                current = ""
            }
            current.append(character)
            previous = category
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func surroundingDifference(_ original: String, _ proposed: String) -> [EditDifference] {
        let old = Array(original), new = Array(proposed)
        var prefix = 0, suffix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        var result: [EditDifference] = []
        append(.unchanged, String(old[..<prefix]), to: &result)
        append(.removed, String(old[prefix..<(old.count - suffix)]), to: &result)
        append(.added, String(new[prefix..<(new.count - suffix)]), to: &result)
        append(.unchanged, String(old[(old.count - suffix)...]), to: &result)
        return result
    }

    private static func append(_ kind: Kind, _ text: String, to result: inout [EditDifference]) {
        guard !text.isEmpty else { return }
        if result.last?.kind == kind { result[result.count - 1].text += text }
        else { result.append(EditDifference(kind: kind, text: text)) }
    }
}

enum NoteEditPreview {
    static func location(of operation: AssistantOperation, in document: NoteDocument) -> String {
        let index = operation.block
        if index == 0 { return operation.action == .insertAfter ? "After the title" : "Note title" }
        let headings: Set<BlockKind> = [.heading1, .heading2, .heading3]
        let heading = (0...index).reversed().first { headings.contains(document.blocks[$0].kind) }
        let name = heading.map { document.blocks[$0].plainText }.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) }
        let anchor = document.blocks[index]
        let start = (heading ?? 0) + 1
        let position = index >= start ? document.blocks[start...index].filter { $0.kind == anchor.kind }.count : 1
        let description = headings.contains(anchor.kind) ? self.name(of: anchor.kind) : "\(self.name(of: anchor.kind)) \(position)"
        let place = name.map { "\($0) · \(description)" } ?? description.capitalized
        return operation.action == .insertAfter ? "After \(place)" : place
    }

    static func name(of kind: BlockKind) -> String {
        switch kind {
        case .body: "paragraph"
        case .bullet: "bullet"
        case .numbered: "numbered item"
        case .checklist: "checklist item"
        default: kind.displayName.lowercased()
        }
    }

    static func removesFormatting(_ operation: AssistantOperation, in document: NoteDocument) -> Bool {
        operation.action == .replace && document.blocks[operation.block].runs.contains {
            !$0.marks.isEmpty || $0.link != nil || $0.highlightColor != nil || $0.ink != nil
        }
    }

    static func fallbackLocation(of operation: AssistantOperation, original: String) -> String {
        if operation.block == 0 { return operation.action == .insertAfter ? "After the title" : "Note title" }
        let excerpt = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = excerpt.isEmpty ? "Empty paragraph" : "\"\(excerpt.prefix(54))\(excerpt.count > 54 ? "…" : "")\""
        return operation.action == .insertAfter ? "After \(place)" : place
    }
}
