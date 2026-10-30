import Foundation

enum SessionTree {
    /// Sort whole families so prioritization never separates a child from its parent.
    static func order(_ rows: [SessionRow]) -> [SessionRow] {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        func root(_ row: SessionRow) -> String {
            var current = row, visited: Set<String> = [row.id]
            while let id = current.parentID, let parent = byID[id] {
                guard visited.insert(id).inserted else { return row.id }
                current = parent
            }
            return current.id
        }
        let groups = Dictionary(grouping: byID.values, by: root)
        let roots = groups.keys.sorted {
            let left = groups[$0]!.sorted(by: SessionRow.precedes).first!
            let right = groups[$1]!.sorted(by: SessionRow.precedes).first!
            return SessionRow.precedes(left, right)
        }
        var output: [SessionRow] = [], visited: Set<String> = []
        func append(_ row: SessionRow, depth: Int, family: [SessionRow]) {
            guard visited.insert(row.id).inserted else { return }
            var row = row; row.depth = depth
            output.append(row)
            guard depth < 32 else { return }
            for child in family.filter({ $0.parentID == row.id }).sorted(by: SessionRow.precedes) {
                append(child, depth: depth + 1, family: family)
            }
        }
        for id in roots {
            let family = groups[id]!
            if let row = byID[id] { append(row, depth: 0, family: family) }
            // Malformed or excessively deep relationships must never hide a row.
            for row in family.sorted(by: SessionRow.precedes) where !visited.contains(row.id) { append(row, depth: 0, family: []) }
        }
        return output
    }

    /// Repeat ancestor context on a continuation page rather than showing orphaned children.
    static func pages(_ rows: [SessionRow], capacity: Int) -> [[SessionRow]] {
        let capacity = max(1, capacity)
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var pages: [[SessionRow]] = [], page: [SessionRow] = []
        for row in rows {
            if page.count == capacity { pages.append(page); page = [] }
            if page.isEmpty, row.depth > 0 {
                var ancestors: [SessionRow] = [], id = row.parentID, seen: Set<String> = [row.id]
                while let parentID = id, seen.insert(parentID).inserted, let parent = byID[parentID] {
                    ancestors.insert(parent, at: 0); id = parent.parentID
                }
                page.append(contentsOf: ancestors.suffix(capacity - 1))
            }
            page.append(row)
        }
        if !page.isEmpty { pages.append(page) }
        return pages.isEmpty ? [[]] : pages
    }
}
