import Foundation

/// The note she sees the first time she opens Notas. Doubles as a feature tour.
enum WelcomeNote {
    static var document: NoteDocument {
        func p(_ kind: BlockKind, _ runs: InlineRun..., checked: Bool? = nil) -> Block {
            Block(kind: kind, checked: checked, runs: runs)
        }
        func t(_ s: String, _ m: InlineMarks = []) -> InlineRun { InlineRun(text: s, marks: m) }

        return NoteDocument(blocks: [
            p(.title, t("Welcome to Notas")),
            p(.body, t("A quiet place for everything you want to remember, and a pretty one too. Here's how it works:")),
            p(.heading2, t("Writing")),
            p(.checklist, t("Type "), t("/", .code), t(" on a new line to add a checklist, heading, quote, divider…"), checked: true),
            p(.checklist, t("Or use shortcuts: "), t("[] ", .code), t("checklist, "), t("- ", .code), t("bullets, "), t("1. ", .code), t("numbers, "), t("# ", .code), t("heading"), checked: false),
            p(.checklist, t("Select text for "), t("bold", .bold), t(", "), t("italic", .italic), t(", "),
              InlineRun(text: "highlights", marks: .highlight, highlightColor: .yellow), t(" and "), InlineRun(text: "colors", ink: .pink), checked: false),
            p(.callout, t("Press "), t("⌘K", .bold), t(" any time to search, jump to a note, or make a new one.")),
            Block(kind: .divider, runs: []),
            p(.heading2, t("Getting around")),
            p(.bullet, t("The colored dots on the left are your notebooks. Click one to see its notes.")),
            p(.bullet, t("Open notes sit as tabs along the top. "), t("⌘T", .bold), t(" for a new note, "), t("⌘W", .bold), t(" to close one.")),
            p(.bullet, t("Tap "), t("Aa", .bold), t(" to give any note its own look: theme, accent, fonts, size.")),
            p(.quote, t("Make it yours. Every note can look exactly how you want.")),
        ])
    }
}
