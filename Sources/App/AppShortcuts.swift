import SwiftUI

/// 拾掇主窗口里所有菜单快捷键的出厂值，只在这里写一次（拾掇 Pro 可以在设置「菜单与快捷键」里改，见 CustomMenuStore.swift）：菜单、按钮的悬停提示、帮助和说明文字都从这里取。
/// 原则：访达里有的组合键，要么做和访达一样的事，要么不用（⇧⌘H 个人文件夹、⇧⌘D 桌面、⇧⌘O 文稿、⌥⌘L 下载……）。
/// 拾掇自己的页面用 ⌃⌘ 加字母（⌃⌘H 首页、⌃⌘E 图片工具……；⌃⌘ 加数字留给「数字键直达」，⌃⌘D 是系统的「查询」、⌃⌘F 全屏、⌃⌘Q 锁屏、⌃⌘空格 表情与符号，都不用）。
/// 找文件更快：⌘L 输入路径（访达的 ⌘L 是「制作替身」，拾掇没有这一项，按用户确认的效果图用 ⌘L）、⇧⌘G 前往文件夹（和访达一样，做同一件事）；
/// 命令面板用 ⌃⌘P（⇧⌘P 在访达和拾掇里都是「显示预览」，不抢）；收藏 1…9 用 ⌥⌘1…9（⌘1 / ⌘2 是「为图标 / 为列表」，⌃⌘ 加数字是「数字键直达」）。
/// ⌥⌘I 在访达里是「检查器」、⌃⌘I 是「显示摘要信息」，所以图片工具用 ⌃⌘E。
/// 右键菜单补齐：⌘X / ⌘C / ⌘V、⌥⌘V 粘贴并移动、⌥⌘C 拷贝路径、⌃⌘N 用所选项目新建文件夹、⌃⌘A 制作替身、⌥⌘⌫ 直接删除、⌘D 复制，都和访达一样
/// （访达以前的「制作替身」是 ⌘L，现在是 ⌃⌘A；⌘L 留给输入路径）。拷贝文字仍是 ⌃⌘C。
enum AppShortcut: String, CaseIterable, Identifiable {
    // 文件
    case newFolder
    case addToFolderWall
    case imageTools
    // 编辑
    case search
    case copyText
    case addToShelf
    // 显示
    case asIcons
    case asList
    case showInfo
    case showPreview
    case toggleToolbar
    case togglePathBar
    case toggleStatusBar
    case viewOptions
    case biggerIcons
    case smallerIcons
    case refresh
    case toggleSidebar
    // 前往
    case back
    case forward
    case enclosingFolder
    case openSelection
    case home
    case homeFolder
    case desktop
    case documents
    case downloads
    case downloadSources
    case duplicates
    case cleanup
    // 找文件更快
    case addressBar
    case goToFolder
    case commandPalette
    // 右键菜单补齐（编辑 / 文件菜单）
    case cut
    case copyItems
    case paste
    case pasteAndMove
    case copyPath
    case newFolderWithSelection
    case makeAlias
    case deleteImmediately
    case duplicate
    // 拾掇 Pro：新建文件模板（访达的 ⌥⌘N 是「新建智能文件夹」，拾掇没有这一项，按效果图用它）
    case newFromLastTemplate
    // 标签页（免费）：⌘T / ⌘W 和访达一样；⌃⇥ / ⌃⇧⇥ 切换（⇧⌘] / ⇧⌘[ 也行）；⇧⌘W 关闭整个窗口
    case newTab
    case closeTab
    case closeWindow
    case nextTab
    case previousTab
    case nextTabAlt
    case previousTabAlt
    // 双栏（Pro）：⌥⌘D 是系统的「隐藏程序坞」，不用；⌘\ 左右双栏、⌥⌘\ 上下排；⌥⌘← / ⌥⌘→ 切到左（上）/ 右（下）栏；
    // 拷贝 / 移动到另一栏 ⌥⇧⌘C / ⌥⇧⌘M（⌥⌘C 已是拷贝路径，⇧⌘C 在访达里是「电脑」，都不抢）
    case dualHorizontal
    case dualVertical
    case focusFirstPane
    case focusSecondPane
    case copyToOtherPane
    case moveToOtherPane

    var id: String { rawValue }

    var key: KeyEquivalent {
        switch self {
        case .newFolder: return "n"
        case .addToFolderWall: return "t"
        case .imageTools: return "e"
        case .search: return "f"
        case .copyText: return "c"
        case .addToShelf: return "b"
        case .asIcons: return "1"
        case .asList: return "2"
        case .showInfo: return "i"
        case .showPreview: return "p"
        case .toggleToolbar: return "t"
        case .togglePathBar: return "p"
        case .toggleStatusBar: return "/"
        case .viewOptions: return "j"
        case .biggerIcons: return "+"
        case .smallerIcons: return "-"
        case .refresh: return "r"
        case .toggleSidebar: return "s"
        case .back: return "["
        case .forward: return "]"
        case .enclosingFolder: return .upArrow
        case .openSelection: return .downArrow
        case .home: return "h"
        case .homeFolder: return "h"
        case .desktop: return "d"
        case .documents: return "o"
        case .downloads: return "l"
        case .downloadSources: return "j"
        case .duplicates: return "u"
        case .cleanup: return "k"
        case .addressBar: return "l"
        case .goToFolder: return "g"
        case .commandPalette: return "p"
        case .cut: return "x"
        case .copyItems: return "c"
        case .paste: return "v"
        case .pasteAndMove: return "v"
        case .copyPath: return "c"
        case .newFolderWithSelection: return "n"
        case .makeAlias: return "a"
        case .deleteImmediately: return .delete
        case .duplicate: return "d"
        case .newFromLastTemplate: return "n"
        case .newTab: return "t"
        case .closeTab: return "w"
        case .closeWindow: return "w"
        case .nextTab, .previousTab: return .tab
        case .nextTabAlt: return "]"
        case .previousTabAlt: return "["
        case .dualHorizontal, .dualVertical: return "\\"
        case .focusFirstPane: return .leftArrow
        case .focusSecondPane: return .rightArrow
        case .copyToOtherPane: return "c"
        case .moveToOtherPane: return "m"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .search, .asIcons, .asList, .showInfo, .toggleStatusBar, .viewOptions, .biggerIcons, .smallerIcons,
             .back, .forward, .enclosingFolder, .openSelection, .addressBar, .cut, .copyItems, .paste, .duplicate,
             .newTab, .closeTab, .dualHorizontal:
            return .command
        case .newFolder, .showPreview, .homeFolder, .desktop, .documents, .downloadSources, .goToFolder,
             .closeWindow, .nextTabAlt, .previousTabAlt:
            return [.command, .shift]
        case .toggleToolbar, .togglePathBar, .refresh, .downloads, .pasteAndMove, .copyPath, .deleteImmediately, .newFromLastTemplate,
             .dualVertical, .focusFirstPane, .focusSecondPane:
            return [.command, .option]
        case .copyToOtherPane, .moveToOtherPane:
            return [.command, .option, .shift]
        case .nextTab:
            return .control
        case .previousTab:
            return [.control, .shift]
        case .addToFolderWall, .imageTools, .copyText, .addToShelf, .toggleSidebar, .home, .duplicates, .cleanup, .commandPalette,
             .newFolderWithSelection, .makeAlias:
            return [.command, .control]
        }
    }

    /// 菜单里的名字（快捷键表、说明文字用）。
    var title: String {
        switch self {
        case .newFolder: return String(localized: "新建文件夹")
        case .addToFolderWall: return String(localized: "添加到文件夹墙…")
        case .imageTools: return String(localized: "图片工具…")
        case .search: return String(localized: "搜索")
        case .copyText: return String(localized: "拷贝文字")
        case .addToShelf: return String(localized: "加入暂存架")
        case .asIcons: return String(localized: "为图标")
        case .asList: return String(localized: "为列表")
        case .showInfo: return String(localized: "显示简介")
        case .showPreview: return String(localized: "显示预览")
        case .toggleToolbar: return String(localized: "隐藏工具栏")
        case .togglePathBar: return String(localized: "隐藏路径栏")
        case .toggleStatusBar: return String(localized: "隐藏状态栏")
        case .viewOptions: return String(localized: "查看显示选项")
        case .biggerIcons: return String(localized: "放大图标")
        case .smallerIcons: return String(localized: "缩小图标")
        case .refresh: return String(localized: "刷新")
        case .toggleSidebar: return String(localized: "隐藏侧边栏")
        case .back: return String(localized: "返回")
        case .forward: return String(localized: "前进")
        case .enclosingFolder: return String(localized: "上一层文件夹")
        case .openSelection: return String(localized: "打开")
        case .home: return String(localized: "首页")
        case .homeFolder: return String(localized: "个人文件夹")
        case .desktop: return String(localized: "桌面")
        case .documents: return String(localized: "文稿")
        case .downloads: return String(localized: "下载")
        case .downloadSources: return String(localized: "下载来源")
        case .duplicates: return String(localized: "重复与相似")
        case .cleanup: return String(localized: "清理")
        case .addressBar: return String(localized: "输入路径…")
        case .goToFolder: return String(localized: "前往文件夹…")
        case .commandPalette: return String(localized: "命令面板…")
        case .cut: return String(localized: "剪切")
        case .copyItems: return String(localized: "拷贝")
        case .paste: return String(localized: "粘贴")
        case .pasteAndMove: return String(localized: "粘贴并移动")
        case .copyPath: return String(localized: "拷贝路径")
        case .newFolderWithSelection: return String(localized: "用所选项目新建文件夹")
        case .makeAlias: return String(localized: "制作替身")
        case .deleteImmediately: return String(localized: "直接删除…")
        case .duplicate: return String(localized: "复制")
        case .newFromLastTemplate: return String(localized: "新建上一次用的模板")
        case .newTab: return String(localized: "新建标签页")
        case .closeTab: return String(localized: "关闭标签页")
        case .closeWindow: return String(localized: "关闭窗口")
        case .nextTab, .nextTabAlt: return String(localized: "显示下一个标签页")
        case .previousTab, .previousTabAlt: return String(localized: "显示上一个标签页")
        case .dualHorizontal: return String(localized: "左右双栏")
        case .dualVertical: return String(localized: "上下排")
        case .focusFirstPane: return String(localized: "切到左边（上面）一栏")
        case .focusSecondPane: return String(localized: "切到右边（下面）一栏")
        case .copyToOtherPane: return String(localized: "拷贝到另一栏")
        case .moveToOtherPane: return String(localized: "移动到另一栏")
        }
    }

    /// 「⇧⌘D」这种写法（修饰键按 ⌃⌥⇧⌘ 的顺序，和系统菜单一样）。
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.keyName(key)
    }

    static func keyName(_ key: KeyEquivalent) -> String {
        switch key {
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .return: return "↩"
        case .delete: return "⌫"
        case .space: return String(localized: "空格")
        case .tab: return "⇥"
        default: return String(key.character).uppercased()
        }
    }

    /// 「返回（⌘[）」这种悬停提示。
    var help: String { String(localized: "\(title)（\(display)）") }

    /// 不在菜单里、由列表自己处理的按键（快捷键表里一起列出来）。
    static let listKeys: [(title: String, keys: String)] = [
        (String(localized: "重命名"), "↩"),
        (String(localized: "打开"), "⌘↓ / ⌘O / " + String(localized: "双击")),
        (String(localized: "快速查看"), String(localized: "空格") + " / ⌘Y"),
        (String(localized: "移到废纸篓"), "⌘⌫"),
        (String(localized: "前往第 1…9 个收藏"), "⌥⌘1…9"),
    ]
}
