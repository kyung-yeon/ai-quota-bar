import Foundation

enum ProgressStatus: String, Codable {
    case pending, inProgress, completed
    init?(wire: String) {
        switch wire {
        case "pending": self = .pending
        case "in_progress", "inProgress": self = .inProgress
        case "completed": self = .completed
        default: return nil
        }
    }
}

struct ProgressStep: Codable, Equatable {
    var id: String
    var title: String
    var status: ProgressStatus
}

/// A provider-reported checklist, never an estimate of time or work performed.
struct SessionProgress: Codable, Equatable {
    var steps: [ProgressStep] = []
    var totalKnown = false
    var isCurrent = true
    var seenCalls: [String] = []
    var completedCount: Int { steps.filter { $0.status == .completed }.count }
    var activeIndices: [Int] { steps.indices.filter { steps[$0].status == .inProgress } }
    var visible: Bool { isCurrent && !steps.isEmpty }
    var summary: String {
        let active = activeIndices
        if !totalKnown {
            return L10n.text("수집된 \(steps.count)개 · \(completedCount)개 완료", "\(completedCount) done · \(steps.count) observed")
        }
        if active.count == 1, let index = active.first {
            return steps[index].title + " · " + L10n.text("\(index + 1)/\(steps.count)단계", "Step \(index + 1)/\(steps.count)")
        }
        let done = L10n.text("\(completedCount)/\(steps.count) 완료", "\(completedCount)/\(steps.count) done")
        return active.isEmpty ? done : done + " · " + L10n.text("\(active.count)개 진행 중", "\(active.count) active")
    }
    var detail: String {
        let heading = L10n.text("완료 \(completedCount) · 전체 \(steps.count)", "Completed \(completedCount) · Total \(steps.count)")
        let scope = totalKnown ? "" : L10n.text("\n수집을 시작하기 전의 작업은 포함되지 않을 수 있습니다.", "\nTasks from before tracking started may be missing.")
        return heading + scope + "\n" + steps.map { step in
            let symbol = step.status == .completed ? "✓" : step.status == .inProgress ? "●" : "○"
            return "\(symbol) \(step.title)"
        }.joined(separator: "\n")
    }
    static func title(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let clean = text.components(separatedBy: .controlCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(160))
    }

    func applying(_ payload: [String: Any], provider: Provider) -> Self? {
        guard payload["hook_event_name"] as? String == "PostToolUse",
              let input = payload["tool_input"] as? [String: Any],
              let call = payload["tool_use_id"] as? String, CompletionEvent.validID(call), !seenCalls.contains(call) else { return nil }
        var next = self
        if provider == .codex {
            guard payload["tool_name"] as? String == "update_plan",
                  payload["tool_response"] as? String == "Plan updated",
                  let plan = input["plan"] as? [[String: Any]], plan.count <= 128 else { return nil }
            var parsed: [ProgressStep] = []
            for (index, item) in plan.enumerated() {
                guard let title = Self.title(item["step"]), let raw = item["status"] as? String,
                      let status = ProgressStatus(wire: raw) else { return nil }
                parsed.append(ProgressStep(id: String(index), title: title, status: status))
            }
            next.steps = parsed
            next.totalKnown = true
        } else {
            guard let tool = payload["tool_name"] as? String,
                  let output = payload["tool_response"] as? [String: Any],
                  next.applyClaude(tool: tool, input: input, output: output) else { return nil }
        }
        next.isCurrent = true
        next.seenCalls = Array((seenCalls + [call]).suffix(256))
        return next
    }
}
