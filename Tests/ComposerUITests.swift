import AppKit

@MainActor func settingsAndComposerUITests(_ expect: (Bool, String) throws -> Void) throws {
    func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
    let name = "AiQuotaBar.ComposerTests.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: name)!
    defer { preferences.removePersistentDomain(forName: name) }
    var reduce = false
    let panel = CompletionPanel(visibleFrames: { [NSRect(x: 0, y: 0, width: 1000, height: 900)] }, preferences: preferences, reduceTransparency: { reduce })
    panel.panel.alphaValue = 0; panel.panel.ignoresMouseEvents = true
    defer { panel.hide() }
    let target = NSObject()
    let menu = PanelSettingsMenu.make(pageSize: 15, translucent: true, target: target, pageAction: #selector(NSObject.description), transparencyAction: #selector(NSObject.description))
    let groups = menu.submenu!.items
    try expect(menu.title == L10n.text("설정", "Settings") && groups.count == 2, "Settings contains floating and transparency groups")
    let pages = groups[0].submenu!.items[0]
    try expect(pages.title == L10n.text("페이지 개수", "Rows per page") && pages.submenu!.items.map(\.tag) == [5, 10, 15, 20], "Page-size list is nested below Floating panel settings")
    try expect(pages.submenu!.items.filter { $0.state == .on }.map(\.tag) == [15] && groups[1].submenu!.items[0].state == .on, "Selected page size and transparency use checkmarks")
    panel.setTransparency(true)
    let effect = all(panel.panel.contentView!).compactMap { $0 as? NSVisualEffectView }.first!
    try expect(!effect.isHidden && effect.blendingMode == .behindWindow && panel.panel.alphaValue == 0, "Transparency uses background vibrancy without fading the whole window")
    let restored = CompletionPanel(preferences: preferences)
    try expect(restored.translucent, "Transparency persists across panel instances")
    reduce = true
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    try expect(effect.isHidden && panel.translucent, "Reduce Transparency overrides the visual effect without losing the preference")
    reduce = false; panel.setTransparency(false)
    try expect(effect.isHidden, "Unchecking transparency restores the opaque surface")
    let event = CompletionEvent(id: "one", providerID: "codex", sessionID: "one", project: "Sample", directory: "/sample", sessionName: "One", completedAt: Date(), destination: SessionDestination(host: .orca, target: "term_one"))
    var row = SessionRow(event: event, isOpen: true)
    var sent: [(String, String)] = [], complete: ((Result<String, Error>) -> Void)?
    panel.onSend = { row, text, done in sent.append((row.id, text)); complete = done }
    panel.showSessions([row], animateNew: false)
    panel.panel.contentView?.layoutSubtreeIfNeeded()
    let input = all(panel.panel.contentView!).compactMap { $0 as? SessionComposer }.first!
    try expect(panel.panel.firstResponder !== input.editor, "Showing the panel never automatically focuses an input or pauses polling")
    input.editor.string = "한국어 요청\n후속 작업"
    input.textDidChange(Notification(name: NSText.didChangeNotification))
    try expect(input.sendButton.isEnabled && input.editor.isEditable, "Idle Orca session accepts a multiline draft")
    panel.panel.makeFirstResponder(input.editor)
    try expect(panel.panel.firstResponder === input.editor, "Nonactivating panel can focus its text editor")
    row.activity = .running
    panel.showSessions([row], animateNew: false)
    try expect(panel.panel.firstResponder === input.editor && input.draft == "한국어 요청\n후속 작업" && !input.sendButton.isEnabled, "Polling preserves editor focus and text while disabling send for running work")
    panel.panel.makeFirstResponder(nil)
    row.activity = .idle; panel.showSessions([row], animateNew: false)
    let retained = all(panel.panel.contentView!).compactMap { $0 as? SessionComposer }.first!
    try expect(retained === input, "Rebuilt cards reuse the same per-session editor")
    let submitKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: panel.panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    try expect(!input.editor.performKeyEquivalent(with: submitKey) && sent.isEmpty, "An unfocused row never steals the focused session's submit shortcut")
    panel.panel.makeFirstResponder(input.editor)
    input.editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    _ = input.editor.performKeyEquivalent(with: submitKey)
    try expect(sent.isEmpty, "Send does not submit an unfinished IME composition")
    input.editor.unmarkText()
    _ = input.editor.performKeyEquivalent(with: submitKey)
    input.submit()
    try expect(sent.count == 1 && sent[0].0 == row.id && input.sending, "Sending locks repeated clicks to one exact session")
    complete?(.failure(PromptSendError.uncertain))
    try expect(!input.draft.isEmpty && !input.sendButton.isEnabled, "An ambiguous delivery keeps the draft and requires manual verification")
    let checked = all(input).compactMap { $0 as? NSButton }.first { $0.title == L10n.text("확인했어요", "Checked") }!
    checked.performClick(nil)
    input.submit(); complete?(.success("Delivered"))
    try expect(input.draft.isEmpty && !input.sending, "Confirmed delivery clears only the submitted draft")
    input.editor.string = "Keep across pages"; input.textDidChange(Notification(name: NSText.didChangeNotification))
    let rows: [SessionRow] = (0..<7).map { index in
        var item = row
        item.event = CompletionEvent(id: "item\(index)", providerID: "codex", sessionID: "item\(index)", project: "Other", directory: "/sample", sessionName: "Other", completedAt: Date(), destination: SessionDestination(host: .orca, target: "term_\(index)"))
        return item
    }
    panel.showSessions([row] + rows, animateNew: false)
    let next = all(panel.panel.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "completion-next-page" }!
    next.performClick(nil)
    let previous = all(panel.panel.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "completion-previous-page" }!
    previous.performClick(nil)
    try expect(all(panel.panel.contentView!).compactMap { $0 as? SessionComposer }.first { $0.row.id == row.id }?.draft == "Keep across pages", "Paging preserves each session's independent draft")
    panel.panel.makeFirstResponder(input.editor)
    panel.showSessions([row] + rows, animateNew: false)
    panel.hide()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    try expect(!panel.panel.isVisible, "Closing while editing with pending refresh never reopens the panel")
    row.opensParent = true; input.update(row)
    try expect(!input.editor.isEditable && !input.sendButton.isEnabled, "Child navigation fallback never enables input to the parent")
    row.opensParent = false; row.isOpen = false; input.update(row)
    try expect(!input.sendButton.isEnabled, "Closed session cannot receive input")
    try expect(all(panel.panel.contentView!).compactMap { $0 as? NSScrollView }.allSatisfy { $0.identifier?.rawValue == "session-input-scroll" }, "Only the bounded text editor scrolls, never the session list")
}
