import AppKit

@MainActor enum PanelSettingsMenu {
    static func make(pageSize: Int, translucent: Bool, target: AnyObject, pageAction: Selector, transparencyAction: Selector) -> NSMenuItem {
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
        floating.submenu?.addItem(pages); settings.submenu?.addItem(floating)
        let transparency = group(L10n.text("투명도", "Transparency"))
        let toggle = NSMenuItem(title: L10n.text("투명도 설정", "Enable transparency"), action: transparencyAction, keyEquivalent: "")
        toggle.target = target; toggle.state = translucent ? .on : .off
        transparency.submenu?.addItem(toggle); settings.submenu?.addItem(transparency)
        return settings
    }
}
