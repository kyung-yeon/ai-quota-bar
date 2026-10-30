import Foundation

// Structured tool outputs: https://code.claude.com/docs/en/agent-sdk/typescript#taskcreate-2
extension SessionProgress {
    mutating func applyClaude(tool: String, input: [String: Any], output: [String: Any]) -> Bool {
        guard output["isError"] as? Bool != true, output["success"] as? Bool != false else { return false }
        switch tool {
        case "TodoWrite", "TaskList":
            let list = (tool == "TodoWrite" ? input["todos"] : output["tasks"]) as? [[String: Any]]
            guard let list, list.count <= 128 else { return false }
            var parsed: [ProgressStep] = []
            for (index, item) in list.enumerated() {
                guard let title = Self.title(item[tool == "TodoWrite" ? "content" : "subject"]),
                      let raw = item["status"] as? String, let status = ProgressStatus(wire: raw),
                      let id = tool == "TodoWrite" ? String(index) : item["id"] as? String,
                      CompletionEvent.validID(id), !parsed.contains(where: { $0.id == id }) else { return false }
                parsed.append(ProgressStep(id: id, title: title, status: status))
            }
            steps = parsed
            totalKnown = true
        case "TaskCreate":
            guard let task = output["task"] as? [String: Any], let id = task["id"] as? String,
                  CompletionEvent.validID(id), let title = Self.title(task["subject"]), steps.count < 128 else { return false }
            // Task creation is idempotent even if a transport redelivers it with another call id.
            if !steps.contains(where: { $0.id == id }) { steps.append(ProgressStep(id: id, title: title, status: .pending)) }
        case "TaskUpdate":
            guard output["success"] as? Bool == true, let id = input["taskId"] as? String,
                  output["taskId"] as? String == id, let fields = output["updatedFields"] as? [String] else { return false }
            guard let index = steps.firstIndex(where: { $0.id == id }) else {
                totalKnown = false
                return true
            }
            if fields.contains("status") {
                let raw = (output["statusChange"] as? [String: Any])?["to"] as? String ?? input["status"] as? String
                if raw == "deleted" { steps.remove(at: index); return true }
                guard let raw, let status = ProgressStatus(wire: raw) else { return false }
                steps[index].status = status
            }
            if fields.contains("subject") {
                guard let title = Self.title(input["subject"]) else { return false }
                steps[index].title = title
            }
        default: return false
        }
        return true
    }
}
