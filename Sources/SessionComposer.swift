import AppKit

final class SessionInput: NSTextView {
    var onSubmit: (() -> Void)?
    override var acceptsFirstResponder: Bool { isEditable }
    override var needsPanelToBecomeKey: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.keyCode == 36 || event.keyCode == 76 {
            if !hasMarkedText() { onSubmit?() }
            return true
        }
        if modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "a": selectAll(nil); return true
            case "c": copy(nil); return true
            case "v": pasteAsPlainText(nil); return true
            case "x": cut(nil); return true
            case "z": undoManager?.undo(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Retain the actual editor per session so paging and polling preserve drafts and IME state.
final class SessionComposer: NSView, NSTextViewDelegate {
    let editor = SessionInput()
    let sendButton = CompletionButton("", symbol: "arrow.up", prominent: true, action: {})
    private let scroll = NSScrollView()
    private let resolved = CompletionButton(L10n.text("확인했어요", "Checked"), plain: true, action: {})
    private var uncertain = false
    private let hint = CompletionCard.label("", size: 10, color: .secondaryLabelColor)
    private let placeholder = CompletionCard.label(L10n.text("후속 요청 입력…", "Write a follow-up…"), size: 11, color: .placeholderTextColor)
    private(set) var row: SessionRow
    private(set) var sending = false
    private(set) var notice: String?
    var onSend: ((SessionRow, String, @escaping (Result<String, Error>) -> Void) -> Void)?
    var onLayoutChanged: (() -> Void)?
    var onEditingEnded: (() -> Void)?
    var isEditing: Bool { editor.isEditable && window?.firstResponder === editor }
    var draft: String { editor.string }
    var preferredHeight: CGFloat { (isEditing || draft.contains("\n") || draft.count > 60 ? 64 : 30) + 20 }
    var supported: Bool { row.isOpen && row.event.destination.host == .orca && !row.opensParent && row.event.destination.herdr == nil }

    init(row: SessionRow) {
        self.row = row
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("session-composer")
        wantsLayer = true; layer?.cornerRadius = 6; layer?.borderWidth = 1
        editor.font = .systemFont(ofSize: 11); editor.isRichText = false; editor.importsGraphics = false
        editor.drawsBackground = false; editor.allowsUndo = true
        editor.textContainerInset = NSSize(width: 4, height: 6)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.delegate = self
        editor.setAccessibilityLabel(L10n.text("\(row.event.project) 후속 요청", "Follow-up for \(row.event.project)"))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = false
        scroll.identifier = NSUserInterfaceItemIdentifier("session-input-scroll")
        scroll.documentView = editor
        [scroll, placeholder, hint, sendButton, resolved].forEach { addSubview($0) }
        sendButton.identifier = NSUserInterfaceItemIdentifier("session-send")
        sendButton.toolTip = L10n.text("전송 (⌘ Enter)", "Send (⌘ Enter)")
        sendButton.setAccessibilityLabel(sendButton.toolTip!)
        sendButton.perform = { [weak self] in self?.submit() }
        editor.onSubmit = { [weak self] in self?.submit() }
        resolved.font = .systemFont(ofSize: 10)
        resolved.toolTip = L10n.text("원래 세션에서 전송 여부를 확인한 후 입력 잠금 해제", "Unlock after checking delivery in the original session")
        resolved.perform = { [weak self] in
            guard let self else { return }
            self.uncertain = false; self.notice = nil; self.update(self.row)
        }
        update(row)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let inputHeight = max(30, bounds.height - 20)
        scroll.frame = NSRect(x: 0, y: 0, width: max(30, bounds.width - 42), height: inputHeight)
        editor.minSize = NSSize(width: scroll.contentSize.width, height: inputHeight)
        editor.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(inputHeight, editor.frame.height)))
        placeholder.frame = NSRect(x: 9, y: 7, width: max(30, bounds.width - 54), height: 18)
        sendButton.frame = NSRect(x: bounds.width - 34, y: 3, width: 26, height: 26)
        hint.frame = NSRect(x: 8, y: inputHeight + 2, width: max(30, bounds.width - (uncertain ? 80 : 16)), height: 16)
        resolved.frame = NSRect(x: bounds.width - 70, y: inputHeight, width: 64, height: 18)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshStyle() }
    private func refreshStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.2).cgColor
        }
    }
    func update(_ row: SessionRow) {
        self.row = row
        editor.isEditable = supported && !sending
        editor.isSelectable = supported
        sendButton.isEnabled = supported && row.activity == .idle && !sending && !uncertain && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        resolved.isHidden = !uncertain
        needsLayout = true
        placeholder.isHidden = !draft.isEmpty
        if sending { hint.stringValue = L10n.text("전송 중…", "Sending…") }
        else if let notice { hint.stringValue = notice }
        else if !row.isOpen { hint.stringValue = L10n.text("종료된 세션", "Session closed") }
        else if !supported { hint.stringValue = L10n.text("이 세션은 직접 입력을 지원하지 않습니다.", "Direct input is unavailable for this session.") }
        else if row.activity == .running { hint.stringValue = L10n.text("작업 중 · 초안 작성 가능", "Working · draft your next request") }
        else if row.activity == .unknown { hint.stringValue = L10n.text("세션 상태 확인 중…", "Checking session status…") }
        else { hint.stringValue = L10n.text("⌘ Enter 전송 · Enter 줄바꿈", "⌘ Enter to send · Enter for a new line") }
        hint.toolTip = hint.stringValue
        refreshStyle()
    }
    func textDidChange(_ notification: Notification) {
        if !uncertain { notice = nil }; update(row); onLayoutChanged?()
    }
    func textDidBeginEditing(_ notification: Notification) { onLayoutChanged?() }
    func textDidEndEditing(_ notification: Notification) { onLayoutChanged?(); onEditingEnded?() }
    func submit() {
        guard sendButton.isEnabled, !editor.hasMarkedText(), let onSend else { return }
        let text = draft
        sending = true; notice = nil; update(row)
        onSend(row, text) { [weak self] result in
            guard let self else { return }
            self.sending = false
            switch result {
            case .success(let message):
                if self.editor.string == text { self.editor.string = ""; self.editor.undoManager?.removeAllActions() }
                self.notice = message
            case .failure(let error):
                self.notice = error.localizedDescription
                self.uncertain = error as? PromptSendError == .uncertain
            }
            self.update(self.row); self.onLayoutChanged?()
        }
    }
}
