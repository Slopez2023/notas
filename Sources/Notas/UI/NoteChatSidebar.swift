import AppKit
import SwiftUI

struct NoteChatSidebar: View {
    let noteID: UUID
    @Environment(AppState.self) private var app
    @State private var replacingKey = false
    @State private var historyID: UUID?
    @State private var keyDraft = ""
    @FocusState private var composing: Bool

    private var assistant: NoteAssistant { app.noteAssistant }
    private var style: ResolvedStyle { app.chromeStyle }
    private var busy: Bool { assistant.busyNotes.contains(noteID) }
    private var current: NoteChatSession { assistant.session(for: noteID) }
    private var displayed: NoteChatSession {
        assistant.archives.first { $0.id == historyID && $0.noteID == noteID } ?? current
    }
    private var isHistory: Bool { historyID != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            if !assistant.hasKey || replacingKey { keyEntry }
            transcript
            if isHistory {
                Button("Return to current conversation") { historyID = nil }
                    .buttonStyle(.bordered).padding(16)
            } else {
                composer
            }
        }
        .foregroundStyle(style.text)
        .background(style.background)
        .alert("Chat needs attention", isPresented: Binding(get: { assistant.error != nil }, set: { if !$0 { assistant.error = nil } })) {
            Button("OK") { assistant.error = nil }
        } message: { Text(assistant.error ?? "") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .foregroundStyle(style.accentColor)
                Text("Note chat").font(.system(size: 14, weight: .semibold))
                Spacer()
                Menu {
                    Button("New conversation") { assistant.newConversation(noteID); historyID = nil }
                        .disabled(busy)
                    let old = assistant.archives.filter { $0.noteID == noteID }.reversed()
                    if !old.isEmpty {
                        Divider()
                        ForEach(Array(old)) { session in
                            Button(String((session.messages.first { $0.role == .user }?.text ?? "Earlier conversation").prefix(48))) {
                                historyID = session.id
                            }
                        }
                    }
                    Divider()
                    Button(assistant.hasKey ? "Replace API key…" : "Add API key…") { replacingKey = true }
                    if assistant.hasKey {
                        Button("Remove API key") { assistant.removeKey(); replacingKey = false }
                            .disabled(!assistant.busyNotes.isEmpty)
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 22, height: 24) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Conversation history and settings")
                Button { app.isChatOpen = false } label: { Image(systemName: "xmark").frame(width: 20, height: 24) }
                    .buttonStyle(.plain).foregroundStyle(style.tertiary).help("Close note chat")
            }
            Text(app.store.notes[noteID]?.displayTitle ?? "Note removed")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(style.secondary).lineLimit(1)
            HStack(spacing: 5) {
                Circle().fill(assistant.hasKey ? Color.green : style.tertiary).frame(width: 5, height: 5)
                Text(isHistory ? "Earlier conversation · read only" : "\(assistant.modelLabel) · medium · this note only")
                    .font(.system(size: 10.5)).foregroundStyle(style.tertiary)
            }
        }
        .padding(16)
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A writing partner for this note")
                .font(.system(size: 15, weight: .semibold, design: .serif))
            Text("Sending a message shares this note's text with OpenCode and its model provider. Photos and files stay on your Mac.")
                .font(.system(size: 12)).foregroundStyle(style.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("OpenCode API key").font(.system(size: 11, weight: .semibold))
                SecureField("Paste your key", text: $keyDraft)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    .onSubmit(saveKey)
                HStack {
                    Button("Save key", action: saveKey)
                        .buttonStyle(.borderedProminent).disabled(keyDraft.isEmpty)
                    if replacingKey { Button("Cancel") { replacingKey = false; keyDraft = "" } }
                }.controlSize(.small)
                Text("Stored in your Keychain. Uses \(assistant.modelLabel) at medium reasoning through OpenCode Go.")
                    .font(.system(size: 10.5)).foregroundStyle(style.tertiary)
            }
        }
        .padding(16)
        .background(style.surface.opacity(0.5))
    }

    private func saveKey() {
        guard !keyDraft.isEmpty else { return }
        assistant.saveKey(keyDraft)
        if assistant.error == nil { replacingKey = false }
        keyDraft = ""
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if displayed.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("What would you like to work on?").font(.system(size: 14, weight: .medium))
                            ForEach(["Help me develop this idea", "Make this note clearer", "Summarize the key points"], id: \.self) { prompt in
                                Button { assistant.setDraft(prompt, for: noteID); composing = true } label: {
                                    Text(prompt).font(.system(size: 12)).foregroundStyle(style.secondary)
                                        .padding(.horizontal, 12).padding(.vertical, 9)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(style.surface, in: RoundedRectangle(cornerRadius: 9))
                                }.buttonStyle(.plain).disabled(isHistory)
                            }
                        }.padding(.vertical, 12)
                    }
                    ForEach(displayed.messages) { message in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(message.role == .user ? "You" : message.role == .assistant ? assistant.modelLabel : "Conversation")
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(style.tertiary)
                            Text(message.text)
                                .font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                                .foregroundStyle(message.role == .notice ? style.secondary : style.text)
                                .fixedSize(horizontal: false, vertical: true)
                            if let proposal = message.proposal { proposalCard(proposal) }
                        }
                        .padding(message.role == .user ? 12 : 0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(message.role == .user ? style.surface : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .id(message.id)
                    }
                    if busy && !isHistory {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Working on this note…").font(.caption).foregroundStyle(style.secondary)
                        }.padding(.vertical, 6)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(16)
            }
            .onChange(of: displayed.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: busy) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func proposalCard(_ proposal: AssistantProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(proposal.state == .applied ? "Applied · ⌘Z to undo" : proposal.state == .dismissed ? "Dismissed" : "Suggested changes")
                .font(.system(size: 11, weight: .semibold))
            ForEach(Array(proposal.operations.enumerated()), id: \.offset) { index, op in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(op.action == .insertAfter ? "Insert after" : op.action == .delete ? "Delete" : "Replace") block \(op.block + 1)")
                        .font(.system(size: 10)).foregroundStyle(style.tertiary)
                    if op.action != .insertAfter, proposal.before.indices.contains(index), !proposal.before[index].isEmpty {
                        Text(proposal.before[index]).strikethrough().foregroundStyle(style.secondary)
                    }
                    if op.action != .delete { Text(op.text).foregroundStyle(style.text) }
                }.font(.system(size: 12)).textSelection(.enabled)
            }
            if proposal.state == .pending && !isHistory {
                HStack {
                    Button("Apply") { assistant.apply(proposal.id, noteID: noteID) }
                        .buttonStyle(.borderedProminent).disabled(busy)
                    Button("Dismiss") { assistant.dismiss(proposal.id, noteID: noteID) }.buttonStyle(.borderless)
                }.controlSize(.small)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(style.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(style.accentColor.opacity(0.2), lineWidth: 0.5))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: Binding(get: { current.draft }, set: { assistant.setDraft($0, for: noteID) }))
                .font(.system(size: 13)).scrollContentBackground(.hidden)
                .frame(height: 68).padding(6)
                .background(style.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if current.draft.isEmpty { Text("Ask about this note…").font(.system(size: 13)).foregroundStyle(style.tertiary).padding(12).allowsHitTesting(false) }
                }
                .focused($composing)
                .accessibilityLabel("Message about this note")
            HStack {
                Text("Changes need your review").font(.system(size: 10)).foregroundStyle(style.tertiary)
                Spacer()
                if busy {
                    Button("Stop", systemImage: "stop.fill") { assistant.stop(noteID) }.controlSize(.small)
                } else {
                    Button("Send", systemImage: "arrow.up") { assistant.send(noteID) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!assistant.hasKey || current.awaitingReply || current.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(16)
        .background(style.background)
    }
}
