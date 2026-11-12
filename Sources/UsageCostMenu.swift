import AppKit

enum UsageCostMenu {
    static func make(_ snapshot: UsageCostSnapshot?, refreshing: Bool) -> NSMenuItem {
        let title = L10n.text("로컬 API 환산 추정", "Local API-equivalent estimate")
        guard let snapshot else {
            let item = NSMenuItem(title: title + L10n.text(" · 조회 중…", " · loading…"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
        let amount = snapshot.estimated > 0 ? usd(snapshot.usd) : L10n.text("추정 불가", "unestimated")
        let partial = snapshot.unestimated > 0 || !snapshot.incompleteSources.isEmpty
        let item = NSMenuItem(title: title + " · " + amount + (partial ? " + ?" : ""), action: nil, keyEquivalent: "")
        let menu = NSMenu()
        add(L10n.text("보존된 로컬 기록 전체 · 실제 청구액 아님", "All retained local history · not your bill"), to: menu)
        add(L10n.text("구독 사용한도와 별개 · USD", "Separate from subscription quota · USD"), to: menu)
        if refreshing { add(L10n.text("갱신 중 · 이전 집계", "Refreshing · previous estimate"), to: menu) }
        if snapshot.groups.isEmpty { add(L10n.text("지원되는 사용량 기록 없음", "No supported usage records"), to: menu) }
        for client in Array(Set(snapshot.groups.map(\.client))).sorted() {
            let groups = snapshot.groups.filter { $0.client == client }
            let known = groups.reduce(0) { $0 + $1.estimated }
            let total = groups.reduce(0) { $0 + $1.usd }
            let unknown = groups.reduce(0) { $0 + $1.unestimated }
            let row = NSMenuItem(title: "\(client) · \(known > 0 ? usd(total) : L10n.text("추정 불가", "unestimated"))\(unknown > 0 ? " + ?" : "")", action: nil, keyEquivalent: "")
            let detail = NSMenu()
            for group in groups {
                add("\(group.provider) / \(group.model)", to: detail)
                let value = group.estimated > 0 ? usd(group.usd) : L10n.text("추정 불가", "unestimated")
                add("  \(value) · \(String(format: "%.0f", group.tokens)) tokens", to: detail)
                if group.unestimated > 0 { add(L10n.text("  추정 불가 기록 \(group.unestimated)개", "  \(group.unestimated) unestimated records"), to: detail) }
                if group.recorded > 0 { add(L10n.text("  클라이언트가 기록한 비용 포함", "  Includes client-recorded estimates"), to: detail) }
            }
            row.submenu = detail; menu.addItem(row)
        }
        if snapshot.unestimated > 0 {
            menu.addItem(.separator())
            add(L10n.text("가격·모델·요청 정보가 없는 기록은 합계 제외", "Missing price/model/request details are excluded"), to: menu)
        }
        if !snapshot.incompleteSources.isEmpty {
            add(L10n.text("일부 기록만 조회됨: ", "Partial scan: ") + snapshot.incompleteSources.sorted().joined(separator: ", "), to: menu)
        }
        add(L10n.text("집계 ", "Scanned ") + dateText(snapshot.scannedAt.timeIntervalSince1970, format: "jms"), to: menu)
        item.submenu = menu
        item.toolTip = L10n.text("현재 API 정가 기준 추정치입니다. 누락된 기록·모델은 0달러로 계산하지 않습니다.", "Estimated at current API list prices. Missing records/models are not priced as zero.")
        return item
    }

    private static func add(_ title: String, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
    }

    private static func usd(_ value: Double) -> String {
        if value > 0 && value < 0.01 { return "< US$0.01" }
        return String(format: "US$%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
