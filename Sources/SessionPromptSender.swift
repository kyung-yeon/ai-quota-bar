import Foundation

enum PromptSubmission: Sendable { case send, queue }

enum PromptSendError: Error, LocalizedError, Equatable {
    case unavailable, notReady, invalidText, uncertain
    var errorDescription: String? {
        switch self {
        case .unavailable: return L10n.text("입력할 수 없습니다. Orca 세션을 확인해 주세요.", "Input unavailable. Check the Orca session.")
        case .notReady: return L10n.text("세션 상태를 확인할 수 없거나 승인 대기 중입니다.", "Session status is unavailable or approval is pending.")
        case .invalidText: return L10n.text("요청은 8,000자 이내로 입력해 주세요.", "Enter a request of up to 8,000 characters.")
        case .uncertain: return L10n.text("일부 입력이 전달됐을 수 있습니다. 세션에서 확인해 주세요.", "Input may have arrived. Check the session before retrying.")
        }
    }
}

enum SessionPromptSender {
    typealias Call = (String, [String: Any]) throws -> [String: Any]
    static func send(_ row: SessionRow, text: String, submission: PromptSubmission = .send) throws -> String {
        let rpc = try OrcaLocalRPC(profile: row.event.destination.profile)
        return try send(row, text: text, submission: submission, call: rpc.call, settle: { Thread.sleep(forTimeInterval: 0.5) })
    }

    /// Match Orca's guarded two-stage prompt input; never fall back to shell/CLI input.
    static func send(_ row: SessionRow, text: String, submission: PromptSubmission = .send, call: Call, settle: () -> Void) throws -> String {
        guard row.isOpen, row.activity != .unknown, !row.opensParent, row.event.destination.host == .orca,
              row.event.destination.herdr == nil else { throw PromptSendError.notReady }
        try SessionNavigator.validate(row.event.destination)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 8000,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else { throw PromptSendError.invalidText }
        let target = row.event.destination.target
        func ready() throws -> (pty: String, working: Bool) {
            let result = try call("terminal.show", ["terminal": target])
            guard let terminal = result["terminal"] as? [String: Any], terminal["handle"] as? String == target,
                  terminal["connected"] as? Bool == true, terminal["orphaned"] as? Bool != true,
                  terminal["agentIdentity"] as? String == row.event.providerID,
                  terminal["executionHostId"] as? String == "local",
                  let pty = terminal["ptyId"] as? String, !pty.isEmpty else { throw PromptSendError.unavailable }
            let resultStatus = try call("terminal.agentStatus", ["terminal": target])
            guard let status = resultStatus["agentStatus"] as? [String: Any], status["handle"] as? String == target,
                  status["isRunningAgent"] as? Bool == true,
                  let activity = status["status"] as? String, ["idle", "working"].contains(activity) else { throw PromptSendError.notReady }
            return (pty, activity == "working")
        }
        let initial = try ready()
        let base: [String: Any] = ["terminal": target, "requireAgentStatus": "sendable", "client": ["id": "aiquotabar", "type": "desktop"]]
        var queued = false
        // From the first write onward, an unacknowledged response cannot prove non-delivery.
        do {
            let paste = try call("terminal.send", base.merging(["text": "\u{1b}[200~" + text + "\u{1b}[201~"]) { _, new in new })
            guard let send = paste["send"] as? [String: Any], send["handle"] as? String == target,
                  send["accepted"] as? Bool == true else { throw PromptSendError.uncertain }
            settle()
            let current = try ready()
            guard current.pty == initial.pty else { throw PromptSendError.uncertain }
            queued = submission == .queue && current.working
            // Codex queues with Tab; Claude queues with Enter. When already idle,
            // Enter starts the next request instead of triggering Tab completion.
            let key: [String: Any] = queued && row.event.providerID == "codex" ? ["text": "\t"] : ["enter": true]
            let submit = try call("terminal.send", base.merging(key) { _, new in new })
            guard let send = submit["send"] as? [String: Any], send["handle"] as? String == target,
                  send["accepted"] as? Bool == true else { throw PromptSendError.uncertain }
        } catch { throw PromptSendError.uncertain }
        return queued ? L10n.text("큐 입력 전달됨", "Queue input delivered") : L10n.text("세션에 전달됨", "Delivered to session")
    }
}
