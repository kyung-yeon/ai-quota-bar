import AppKit

@MainActor private final class TransparencyMenuFixture: NSObject {
    var select: ((Int) -> Void)?
    @objc func setPercentage(_ item: NSMenuItem) { select?(item.tag) }
}

@MainActor func settingsAndComposerUITests(_ expect: (Bool, String) throws -> Void) throws {
    func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
    let name = "AiQuotaBar.ComposerTests.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: name)!
    defer { preferences.removePersistentDomain(forName: name) }
    var reduce = false
    let panel = CompletionPanel(visibleFrames: { [NSRect(x: 0, y: 0, width: 1000, height: 900)] }, preferences: preferences, reduceTransparency: { reduce })
    panel.panel.alphaValue = 0; panel.panel.ignoresMouseEvents = true
    defer { panel.hide() }
    let target = TransparencyMenuFixture()
    let menu = PanelSettingsMenu.make(pageSize: 15, translucent: true, transparencyPercent: 70, target: target,
        pageAction: #selector(NSObject.description), transparencyAction: #selector(NSObject.description), percentageAction: #selector(TransparencyMenuFixture.setPercentage(_:)))
    let groups = menu.submenu!.items
    try expect(menu.title == L10n.text("설정", "Settings") && groups.count == 2, "Settings contains floating and transparency groups")
    let pages = groups[0].submenu!.items[0]
    try expect(pages.title == L10n.text("페이지 개수", "Rows per page") && pages.submenu!.items.filter { $0.action != nil }.map(\.tag) == [1, 2, 3, 5, 10, 15, 20], "Page-size list includes useful small capacities below Floating panel settings")
    try expect(pages.submenu!.items.filter { $0.state == .on }.map(\.tag) == [15] && groups[1].submenu!.items[0].state == .on, "Selected page size and transparency use checkmarks")
    let percentageAction = #selector(TransparencyMenuFixture.setPercentage(_:))
    try expect(groups[1].submenu!.items.filter { $0.action == percentageAction }.map(\.tag) == Array(stride(from: 0, through: 100, by: 10)),
        "Transparency offers every ten-percent level from 0 through 100")
    panel.setTransparencyPercent(0)
    try expect(panel.transparencyPercent == 0, "Zero percent is a saved opaque endpoint, not the default value")
    try expect(CompletionPanel(preferences: preferences).transparencyPercent == 0, "Zero percent stays opaque after relaunch")
    preferences.removeObject(forKey: "backgroundTransparencyPercent")
    panel.setTransparency(true)
    let effect = all(panel.panel.contentView!).compactMap { $0 as? NSVisualEffectView }.first!
    try expect(!effect.isHidden && effect.blendingMode == .behindWindow && panel.panel.alphaValue == 0, "Transparency uses background vibrancy without fading the whole window")
    try expect(effect.maskImage == nil && effect.layer?.masksToBounds != true,
        "The floating backdrop fills the native window instead of drawing an inset rounded window")
    let usage = StatusMenuPanel(preferences: preferences, reduceTransparency: { reduce })
    let usageEffect = all(usage.panel.contentView!).compactMap { $0 as? NSVisualEffectView }.first!
    let tints = [effect, usageEffect].map { all($0).first { $0.identifier?.rawValue == "glass-tint" } as! CompletionSurface }
    try expect(panel.transparencyPercent == 70, "Existing transparency users without a percentage get the default 70 percent")
    target.select = { panel.setTransparencyPercent($0); usage.updateAppearance() }
    for item in groups[1].submenu!.items where item.action == percentageAction {
        panel.setTransparency(false)
        NSApp.sendAction(item.action!, to: item.target, from: item)
        try expect(panel.translucent && panel.transparencyPercent == item.tag && !usageEffect.isHidden,
            "Choosing \(item.tag) percent enables and saves the shared transparency setting")
        try expect(tints.allSatisfy { abs($0.fillOpacity - (1 - CGFloat(item.tag) / 100)) < 0.001 }
            && [effect, usageEffect].allSatisfy { abs($0.alphaValue - (1 - CGFloat(item.tag) / 100)) < 0.001 },
            "\(item.tag) percent changes both complete backdrops, including the native material")
        let updated = PanelSettingsMenu.make(pageSize: 15, translucent: panel.translucent, transparencyPercent: panel.transparencyPercent,
            target: target, pageAction: #selector(NSObject.description), transparencyAction: #selector(NSObject.description),
            percentageAction: #selector(TransparencyMenuFixture.setPercentage(_:)))
        try expect(updated.submenu!.items[1].submenu!.items.filter { $0.action == percentageAction && $0.state == .on }.map(\.tag) == [item.tag],
            "Reopening the settings marks only the selected percentage")
    }
    panel.setTransparencyPercent(40)
    for invalid in [-10, 15, 110] { panel.setTransparencyPercent(invalid) }
    try expect(panel.transparencyPercent == 40, "Invalid percentage values cannot overwrite the saved choice")
    let restored = CompletionPanel(preferences: preferences)
    try expect(restored.translucent && restored.transparencyPercent == 40, "Transparency and percentage persist across panel instances")
    reduce = true
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    try expect(effect.isHidden && panel.translucent, "Reduce Transparency overrides the visual effect without losing the preference")
    reduce = false; panel.setTransparency(false)
    try expect(effect.isHidden, "Unchecking transparency restores the opaque surface")
    panel.setTransparency(true)
    try expect(!effect.isHidden && panel.transparencyPercent == 40, "Re-enabling transparency restores the previous percentage")
    preferences.set(17, forKey: "backgroundTransparencyPercent")
    try expect(panel.transparencyPercent == 70, "An unsupported stored percentage falls back to 70 percent")
    panel.setTransparency(false)
    let event = CompletionEvent(id: "one", providerID: "codex", sessionID: "one", project: "Sample", directory: "/sample", sessionName: "One", completedAt: Date(), destination: SessionDestination(host: .orca, target: "term_one"))
    var row = SessionRow(event: event, isOpen: true)
    var sent: [(String, String, PromptSubmission)] = [], complete: ((Result<String, Error>) -> Void)?
    panel.onSend = { row, text, mode, done in sent.append((row.id, text, mode)); complete = done }
    panel.showSessions([row], animateNew: false)
    panel.panel.contentView?.layoutSubtreeIfNeeded()
    let input = all(panel.panel.contentView!).compactMap { $0 as? SessionComposer }.first!
    for percent in [0, 100, 70] {
        panel.setTransparencyPercent(percent)
        let surfaces = all(panel.panel.contentView!).compactMap { $0 as? CompletionCard }.flatMap { all($0).compactMap { $0 as? CompletionSurface } }
        try expect(!surfaces.isEmpty && surfaces.allSatisfy { abs($0.fillOpacity - (1 - CGFloat(percent) / 100)) < 0.001 }
            && input.alphaValue == 1 && input.editor.alphaValue == 1,
            "Session card backgrounds follow \(percent) percent while editors stay legible")
    }
    try expect(panel.panel.firstResponder !== input.editor, "Showing the panel never automatically focuses an input or pauses polling")
    let placeholderPoint = input.convert(NSPoint(x: 20, y: 14), to: panel.panel.contentView!)
    try expect(panel.panel.contentView!.hitTest(placeholderPoint) === input.editor,
        "Clicking the empty input placeholder reaches the actual text editor")
    try expect(input.editor.acceptsFirstMouse(for: nil) && input.editor.needsPanelToBecomeKey && !input.editor.mouseDownCanMoveWindow,
        "Input accepts the first click and does not drag the floating window")
    input.editor.string = "한국어 요청\n후속 작업"
    input.textDidChange(Notification(name: NSText.didChangeNotification))
    try expect(input.sendButton.isEnabled && input.editor.isEditable, "Idle Orca session accepts a multiline draft")
    panel.panel.makeFirstResponder(input.editor)
    try expect(panel.panel.firstResponder === input.editor, "Nonactivating panel can focus its text editor")
    row.activity = .running
    panel.showSessions([row], animateNew: false)
    try expect(panel.panel.firstResponder === input.editor && input.draft == "한국어 요청\n후속 작업" && input.sendButton.isEnabled, "Polling preserves editor focus and text while allowing send for running work")
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
    key(36, "\r")
    try expect(sent.isEmpty, "Plain Enter commits marked text without sending the request")
    input.editor.setMarkedText("글", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    key(48, "\t")
    try expect(sent.isEmpty, "Tab during IME composition never queues an unfinished request")
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
    row.activity = .running; input.update(row)
    panel.panel.makeFirstResponder(input.editor)
    func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: panel.panel.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        input.editor.keyDown(with: event)
    }
    input.editor.insertText("작업 중 요청", replacementRange: NSRange(location: NSNotFound, length: 0))
    let beforeNewline = sent.count
    key(36, "\r", flags: .shift)
    try expect(input.draft == "작업 중 요청\n" && sent.count == beforeNewline,
        "Shift Enter inserts a newline without sending while work is running")
    input.editor.insertText("두 번째 줄", replacementRange: NSRange(location: NSNotFound, length: 0))
    key(36, "\r")
    try expect(sent.last?.1 == "작업 중 요청\n두 번째 줄" && sent.last?.2 == .send && input.sending,
        "Plain Enter submits the complete multiline request during running work")
    complete?(.success("Delivered"))
    input.editor.insertText("다음 작업", replacementRange: NSRange(location: NSNotFound, length: 0))
    key(48, "\t")
    try expect(sent.last?.1 == "다음 작업" && sent.last?.2 == .queue && input.sending,
        "Tab queues the focused session's draft instead of inserting a tab or moving focus")
    complete?(.success("Queue input delivered"))
    try expect(input.draft.isEmpty, "A delivered queue request clears its draft")
    row.activity = .unknown; input.update(row)
    input.editor.insertText("Keep until ready", replacementRange: NSRange(location: NSNotFound, length: 0))
    let beforeUnknown = sent.count
    key(36, "\r"); key(48, "\t")
    try expect(sent.count == beforeUnknown && input.draft == "Keep until ready", "Unknown status preserves typing but blocks both send and queue")
    row.activity = .idle; input.update(row)
    panel.panel.makeFirstResponder(nil)
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
