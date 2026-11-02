import Foundation

enum SessionStatusFilter: String, CaseIterable {
    case all, completed, running

    func matches(_ row: SessionRow) -> Bool {
        switch self {
        case .all: return true
        case .completed: return row.needsAttention
        case .running: return row.isOpen && row.activity == .running
        }
    }

    func title(count: Int) -> String {
        switch self {
        case .all: return L10n.text("전체 \(count)개", "All \(count)")
        case .completed: return L10n.text("완료 \(count)건", "Done \(count)")
        case .running: return L10n.text("작업 중 \(count)건", "Working \(count)")
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: return L10n.text("열려 있는 AI 세션을 기다리는 중입니다.", "Waiting for an open AI session.")
        case .completed: return L10n.text("확인하지 않은 완료 응답이 없습니다.", "No unacknowledged completions.")
        case .running: return L10n.text("현재 작업 중인 세션이 없습니다.", "No sessions are currently working.")
        }
    }

    func apply(to rows: [SessionRow]) -> [SessionRow] {
        guard self != .all else { return rows }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let matches = rows.filter(matches)
        var included = Set(matches.map(\.id))
        for row in matches {
            var parentID = row.parentID, visited: Set<String> = [row.id]
            while let id = parentID, visited.insert(id).inserted, let parent = byID[id] {
                included.insert(id)
                parentID = parent.parentID
            }
        }
        return rows.filter { included.contains($0.id) }
    }
}
