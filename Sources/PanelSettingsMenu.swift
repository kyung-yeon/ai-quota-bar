import AppKit

@MainActor enum PanelSettingsMenu {
    static func make(pageSize: Int, translucent: Bool, transparencyPercent: Int, target: AnyObject,
                     pageAction: Selector, transparencyAction: Selector, percentageAction: Selector) -> NSMenuItem {
        func group(_ title: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(); item.submenu?.autoenablesItems = false
            return item
        }
        let settings = group(L10n.text("설정", "Settings"))
        let floating = group(L10n.text("플로팅 설정", "Floating panel settings"))
        let pages = group(L10n.text("페이지 개수", "Rows per page"))
        for size in CompletionPanel.pageSizeOptions {
            let item = NSMenuItem(title: L10n.text("\(size)개", "\(size) rows"), action: pageAction, keyEquivalent: "")
            item.tag = size; item.target = target; item.state = pageSize == size ? .on : .off
            pages.submenu?.addItem(item)
        }
        pages.submenu?.addItem(.separator())
        let hint = NSMenuItem(title: L10n.text("화면 높이에 맞춰 더 적게 표시될 수 있습니다.", "Fewer rows may fit on your screen."), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        pages.submenu?.addItem(hint)
        floating.submenu?.addItem(pages); settings.submenu?.addItem(floating)
        let transparency = group(L10n.text("투명도", "Transparency"))
        let toggle = NSMenuItem(title: L10n.text("투명도 설정", "Enable transparency"), action: transparencyAction, keyEquivalent: "")
        toggle.target = target; toggle.state = translucent ? .on : .off
        transparency.submenu?.addItem(toggle)
        transparency.submenu?.addItem(.separator())
        for percent in CompletionGlass.percentages {
            let item = NSMenuItem(title: "\(percent)%", action: percentageAction, keyEquivalent: "")
            item.tag = percent; item.target = target
            item.state = translucent && transparencyPercent == percent ? .on : .off
            transparency.submenu?.addItem(item)
        }
        transparency.submenu?.addItem(.separator())
        let transparencyHint = NSMenuItem(title: L10n.text("높을수록 배경이 더 비칩니다.", "Higher values show more of the background."), action: nil, keyEquivalent: "")
        transparencyHint.isEnabled = false
        transparency.submenu?.addItem(transparencyHint)
        settings.submenu?.addItem(transparency)
        return settings
    }
}
