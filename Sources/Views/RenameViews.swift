import OSLog
import AppKit
import CoreServices
import ImageIO
import SwiftUI

enum RenameMode: String, CaseIterable, Identifiable {
    case sequence, date, captureTime, replace, affix
    /// 拾掇 Pro：规则组合（预设、正则、序号、日期……依次生效）。
    case rules
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sequence: return String(localized: "名称 + 序号")
        case .date: return String(localized: "修改日期")
        case .captureTime: return String(localized: "拍摄时间")
        case .replace: return String(localized: "替换文字")
        case .affix: return String(localized: "加前缀 / 后缀")
        case .rules: return String(localized: "规则 · Pro")
        }
    }
}

struct RenamePlan: Identifiable {
    let item: FileItem
    let newName: String
    var id: String { item.id }
    var changed: Bool { newName != item.name }
}

enum Renamer {
    /// 照片的拍摄时间：EXIF → Spotlight 内容创建时间 → 修改时间。
    static func captureDate(_ item: FileItem) -> Date {
        if let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let date = f.date(from: raw) { return date }
        }
        if let md = MDItemCreateWithURL(kCFAllocatorDefault, item.url as CFURL),
           let date = MDItemCopyAttribute(md, kMDItemContentCreationDate) as? Date {
            return date
        }
        return item.created ?? item.sortDate
    }

    static func plan(
        _ items: [FileItem], mode: RenameMode, base: String, start: Int, digits: Int,
        dateFormat: String, find: String, replace: String, prefix: String, suffix: String
    ) -> [RenamePlan] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = dateFormat.isEmpty ? "yyyy-MM-dd" : dateFormat

        var dates: [String: Date] = [:]
        if mode == .captureTime {
            for item in items { dates[item.id] = captureDate(item) }
        } else if mode == .date {
            for item in items { dates[item.id] = item.sortDate }
        }
        let ordered: [FileItem]
        switch mode {
        case .date, .captureTime:
            ordered = items.sorted { (dates[$0.id] ?? .distantPast) < (dates[$1.id] ?? .distantPast) }
        default:
            ordered = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        var stems: [String] = []
        for (index, item) in ordered.enumerated() {
            let stem = (item.name as NSString).deletingPathExtension
            switch mode {
            case .sequence:
                let number = String(format: "%0\(max(1, digits))d", start + index)
                let b = base.trimmingCharacters(in: .whitespaces)
                stems.append(b.isEmpty ? number : "\(b)_\(number)")
            case .date, .captureTime:
                stems.append(formatter.string(from: dates[item.id] ?? item.sortDate))
            case .replace:
                stems.append(find.isEmpty ? stem : stem.replacingOccurrences(of: find, with: replace))
            case .affix:
                stems.append(prefix + stem + suffix)
            case .rules:
                // 规则模式走 RenameEngine（RenameSheet.refreshRules），这里只保持原名。
                stems.append(stem)
            }
        }

        // 同名的加 _2、_3……；也避开文件夹里已有的其他文件。
        var taken: [String: Set<String>] = [:]
        let renaming = Set(ordered.map(\.path))
        var result: [RenamePlan] = []
        for (item, rawStem) in zip(ordered, stems) {
            let dir = (item.path as NSString).deletingLastPathComponent
            if taken[dir] == nil {
                let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                taken[dir] = Set(existing.filter { !renaming.contains((dir as NSString).appendingPathComponent($0)) }.map { $0.lowercased() })
            }
            let ext = (item.name as NSString).pathExtension
            let cleanStem = rawStem.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            func name(_ n: Int) -> String {
                let s = n == 1 ? cleanStem : "\(cleanStem)_\(n)"
                return ext.isEmpty ? s : "\(s).\(ext)"
            }
            var n = 1
            while taken[dir]!.contains(name(n).lowercased()) { n += 1 }
            let final = name(n)
            taken[dir]!.insert(final.lowercased())
            result.append(RenamePlan(item: item, newName: final))
        }
        return result
    }

    /// 两步改名时用的临时名：不以点开头（中途崩溃也不会变成看不见的隐藏文件），一看就知道原名。
    static func temporaryName(for name: String) -> String {
        "\(name).shiduo-renaming-\(UUID().uuidString.prefix(8))"
    }

    /// 两步改名（先改成临时名），避免 a→b、b→a 互相覆盖。返回成功数和失败的文件名。
    static func apply(_ plans: [RenamePlan]) -> (done: [(old: URL, new: URL)], failed: [String]) {
        let fm = FileManager.default
        var temps: [(RenamePlan, URL)] = []
        var failed: [String] = []
        for plan in plans where plan.changed {
            let tmp = plan.item.url.deletingLastPathComponent()
                .appendingPathComponent(temporaryName(for: plan.item.name))
            do {
                try fm.moveItem(at: plan.item.url, to: tmp)
                temps.append((plan, tmp))
            } catch {
                AppLog.files.error("Rename failed: \(AppLog.describe(error), privacy: .public)")
                failed.append(plan.item.name)
            }
        }
        var done: [(URL, URL)] = []
        for (plan, tmp) in temps {
            let target = plan.item.url.deletingLastPathComponent().appendingPathComponent(plan.newName)
            do {
                try fm.moveItem(at: tmp, to: target)
                done.append((plan.item.url, target))
            } catch {
                try? fm.moveItem(at: tmp, to: plan.item.url)
                failed.append(plan.item.name)
            }
        }
        // 名字互换（a↔b、按拍摄时间重新编号）后同一路径换成了别的文件：缩略图要重新取。
        ThumbnailService.shared.invalidate(done.flatMap { [$0.0, $0.1] })
        return (done, failed)
    }

    /// 撤销一次重命名：把每个文件改回原来的名字（同样两步改名，避免互相覆盖）。
    /// 已经不在新位置的文件、原名又被别的文件占了的跳过。
    static func undo(_ done: [(old: URL, new: URL)]) -> (done: [(old: URL, new: URL)], failed: [String]) {
        let fm = FileManager.default
        var plans: [RenamePlan] = []
        var failed: [String] = []
        let renamedNow = Set(done.map { $0.new.standardizedFileURL.path })
        for pair in done {
            guard let item = FileItem(url: pair.new) else {
                failed.append(pair.new.lastPathComponent)
                continue
            }
            let original = pair.old.standardizedFileURL.path
            // 原名被别的文件占了（不是这批里正要改回去的）：不覆盖。
            if fm.fileExists(atPath: original), !renamedNow.contains(original) {
                failed.append(pair.new.lastPathComponent)
                continue
            }
            plans.append(RenamePlan(item: item, newName: pair.old.lastPathComponent))
        }
        let outcome = apply(plans)
        return (outcome.done, failed + outcome.failed)
    }
}

struct RenameSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var license = LicenseManager.shared
    @Environment(\.dismiss) private var dismiss
    let items: [FileItem]

    @AppStorage("renameMode") private var mode: RenameMode = .sequence
    @State private var base = ""
    @State private var start = 1
    @State private var digits = 3
    @AppStorage("renameDateFormat") private var dateFormat = "yyyy-MM-dd"
    @AppStorage("renameCaptureFormat") private var captureFormat = "yyyyMMdd_HHmmss"
    @State private var find = ""
    @State private var replace = ""
    @State private var prefix = ""
    @State private var suffix = ""
    @State private var plans: [RenamePlan] = []

    // 拾掇 Pro：规则模式
    /// 上一次用的规则（下次打开接着用）。
    @AppStorage("renameRules.last") private var lastRulesData = Data()
    @State private var steps: [RenameStep] = []
    @State private var userPresets: [RenamePreset] = RenamePresets.decode(UserDefaults.standard.data(forKey: RenamePresets.defaultsKey))
    @State private var result = RenameResult(outcomes: [], regexError: nil)
    /// 各个文件夹里已有的名字（小写，后台读一次）。
    @State private var existing: [String: Set<String>] = [:]
    /// 照片的拍摄日期（用到「拍摄日期」时后台读一次）。
    @State private var captureDates: [String: Date] = [:]
    @State private var loadingCaptureDates = false

    private var isRules: Bool { mode == .rules }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(items.count > 1 ? String(localized: "批量重命名 \(items.count) 个文件") : String(localized: "重命名"))
                    .font(.title2.bold())
                if isRules { ProBadge() }
            }
            presetRow
            Picker("方式", selection: $mode) {
                ForEach(RenameMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if isRules {
                rulesEditor
            } else {
                options
                    .frame(minHeight: 64, alignment: .top)
            }

            Text("预览")
                .font(.headline)
            List(Array(plans.enumerated()), id: \.element.id) { pair in
                previewRow(pair.element, outcome: isRules && pair.offset < result.outcomes.count ? result.outcomes[pair.offset] : nil)
            }
            .frame(minHeight: isRules ? 180 : 220)

            HStack {
                footerText
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("重命名") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            }
        }
        .padding(22)
        .frame(width: isRules ? 760 : 640, height: isRules ? 680 : 600)
        .onAppear {
            if steps.isEmpty {
                steps = RenamePresets.decodeSteps(lastRulesData) ?? [RenameStep(kind: .replace)]
            }
            loadExisting()
            refresh()
        }
        .onChange(of: mode) { refresh() }
        .onChange(of: base) { refresh() }
        .onChange(of: start) { refresh() }
        .onChange(of: digits) { refresh() }
        .onChange(of: dateFormat) { refresh() }
        .onChange(of: captureFormat) { refresh() }
        .onChange(of: find) { refresh() }
        .onChange(of: replace) { refresh() }
        .onChange(of: prefix) { refresh() }
        .onChange(of: suffix) { refresh() }
        .onChange(of: steps) {
            lastRulesData = RenamePresets.encodeSteps(steps) ?? Data()
            refresh()
        }
        .onChange(of: existing) { refresh() }
        .onChange(of: captureDates) { refresh() }
    }

    private var canApply: Bool {
        if isRules { return license.isPro && result.canApply }
        return plans.contains(where: \.changed)
    }

    @ViewBuilder
    private var footerText: some View {
        if isRules {
            if !license.isPro {
                Text("规则组合、正则和预设是拾掇 Pro 的功能")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if result.regexError != nil {
                Text("正则表达式有错，改好才能改名")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if result.problemCount > 0 {
                Text("有 \(result.problemCount) 个名字有问题（标红的），改好才能改名")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("实时预览，改名后 ⌘Z 一次全部撤销；可以存成预设下次直接用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("\(plans.filter(\.changed).count) 个文件会改名，扩展名保持不变")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 预览

    private func previewRow(_ plan: RenamePlan, outcome: RenameOutcome?) -> some View {
        HStack(spacing: 8) {
            Text(plan.item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(plan.newName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fontWeight(plan.changed ? .semibold : .regular)
                    .foregroundStyle(color(for: outcome, changed: plan.changed))
                if let note = note(for: outcome) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(outcome?.issue == .existing ? Color.orange : Color.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func color(for outcome: RenameOutcome?, changed: Bool) -> Color {
        guard let outcome else { return .primary }
        switch outcome.issue {
        case .illegal, .duplicate: return .red
        case .existing: return .orange
        case nil: return changed ? .green : .secondary
        }
    }

    private func note(for outcome: RenameOutcome?) -> String? {
        switch outcome?.issue {
        case .illegal: return String(localized: "名字不能用：不能为空、不能有「/」「:」、不能以「.」开头")
        case .duplicate: return String(localized: "和这一批里的其他文件重名")
        case .existing: return String(localized: "和已有文件重名，会自动加 (1)")
        default: return nil
        }
    }

    // MARK: 常用预设

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("常用预设")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                if !license.isPro { ProBadge() }
                ForEach(RenamePresets.builtIns) { preset in
                    Button(preset.name) { use(preset) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if !userPresets.isEmpty {
                    Divider().frame(height: 16)
                }
                ForEach(userPresets) { preset in
                    Button {
                        use(preset)
                    } label: {
                        Label(preset.name, systemImage: "star.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("右键可以重命名或删除这个预设")
                    .stableContextMenu {
                        Button("重命名预设…") { renamePreset(preset) }
                        Button("删除预设", role: .destructive) { deletePreset(preset) }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// 点一个预设：换成它的规则，切到规则模式（没解锁 Pro 时弹升级面板）。
    private func use(_ preset: RenamePreset) {
        guard license.isPro else {
            showPaywall()
            return
        }
        steps = preset.steps.map { step in
            var copy = step
            copy.id = UUID()
            return copy
        }
        mode = .rules
    }

    private func savePreset() {
        guard let name = askName(title: String(localized: "存为预设"), initial: "") else { return }
        userPresets = RenamePresets.saving(name, steps: steps, into: userPresets)
        persistPresets()
        store.showToast(String(localized: "已存为预设：\(name)"))
    }

    private func renamePreset(_ preset: RenamePreset) {
        guard let name = askName(title: String(localized: "重命名预设"), initial: preset.name) else { return }
        userPresets = RenamePresets.renaming(preset.id, to: name, in: userPresets)
        persistPresets()
    }

    private func deletePreset(_ preset: RenamePreset) {
        userPresets = RenamePresets.deleting(preset.id, from: userPresets)
        persistPresets()
    }

    private func persistPresets() {
        UserDefaults.standard.set(RenamePresets.encode(userPresets), forKey: RenamePresets.defaultsKey)
    }

    private func askName(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: String(localized: "存好"))
        alert.addButton(withTitle: String(localized: "取消"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = String(localized: "预设名称，例如「活动照片」")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func showPaywall() {
        NSApp.activate(ignoringOtherApps: true)
        LicenseManager.shared.showPaywall = true
    }

    // MARK: 规则

    @ViewBuilder
    private var rulesEditor: some View {
        if !license.isPro {
            HStack(spacing: 10) {
                ProBadge()
                Text("规则组合（序号、日期、大小写、正则查找替换……）和预设是拾掇 Pro 的功能，可以先免费试用。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("了解拾掇 Pro") { showPaywall() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.08)))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach($steps) { $step in
                            let index = steps.firstIndex(where: { $0.id == step.id }) ?? 0
                            RenameStepRow(step: $step, number: index + 1,
                                          canMoveUp: index > 0, canMoveDown: index < steps.count - 1,
                                          move: { offset in moveStep(step.id, by: offset) },
                                          delete: { steps.removeAll { $0.id == step.id } })
                        }
                    }
                }
                .frame(minHeight: 60, maxHeight: 200)
                HStack(spacing: 10) {
                    Menu {
                        ForEach(RenameStep.Kind.allCases, id: \.self) { kind in
                            Button(kind.title) { steps.append(RenameStep(kind: kind)) }
                        }
                    } label: {
                        Label("添加规则", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Text("规则从上往下依次生效")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("存为预设…") { savePreset() }
                        .disabled(steps.isEmpty)
                }
                if let error = result.regexError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if loadingCaptureDates {
                    Text("正在读取照片的拍摄日期…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func moveStep(_ id: UUID, by offset: Int) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard steps.indices.contains(target) else { return }
        steps.swapAt(index, target)
    }

    // MARK: 简单模式（免费）

    @ViewBuilder
    private var options: some View {
        switch mode {
        case .sequence:
            HStack(spacing: 12) {
                TextField("名称，例如“旅行”", text: $base)
                    .textFieldStyle(.roundedBorder)
                Stepper("从 \(start) 开始", value: $start, in: 0...99999)
                Picker("位数", selection: $digits) {
                    Text("1").tag(1); Text("01").tag(2); Text("001").tag(3); Text("0001").tag(4)
                }
                .frame(width: 130)
            }
        case .date:
            formatPicker($dateFormat, options: ["yyyy-MM-dd", "yyyyMMdd", "yyyy-MM-dd HH.mm.ss", "yyyy年M月d日"])
        case .captureTime:
            VStack(alignment: .leading, spacing: 6) {
                formatPicker($captureFormat, options: ["yyyyMMdd_HHmmss", "yyyy-MM-dd HH.mm.ss", "yyyy-MM-dd", "yyyy年M月d日 HH.mm"])
                Text("照片读取相机记录的拍摄时间；没有记录的按创建时间。同一秒的会自动加 _2。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .replace:
            HStack(spacing: 12) {
                TextField("查找", text: $find).textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("替换为（留空表示删除）", text: $replace).textFieldStyle(.roundedBorder)
            }
        case .affix:
            HStack(spacing: 12) {
                TextField("前缀", text: $prefix).textFieldStyle(.roundedBorder)
                Text("原名").foregroundStyle(.secondary)
                TextField("后缀", text: $suffix).textFieldStyle(.roundedBorder)
            }
        case .rules:
            EmptyView()
        }
    }

    private func formatPicker(_ binding: Binding<String>, options: [String]) -> some View {
        Picker("格式", selection: binding) {
            ForEach(options, id: \.self) { f in
                Text(example(f)).tag(f)
            }
        }
        .frame(maxWidth: 360)
    }

    private func example(_ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: Date())
    }

    private func refresh() {
        if isRules {
            refreshRules()
            return
        }
        plans = Renamer.plan(
            items, mode: mode, base: base, start: start, digits: digits,
            dateFormat: mode == .captureTime ? captureFormat : dateFormat,
            find: find, replace: replace, prefix: prefix, suffix: suffix
        )
    }

    /// 规则模式：按名字排好（序号按这个顺序），交给 RenameEngine 算新名字、标出问题。
    private func refreshRules() {
        let ordered = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if steps.contains(where: { $0.kind == .date && $0.dateSource == .captured }) { loadCaptureDates() }
        let inputs = ordered.map { item in
            RenameInput(name: item.name, directory: item.url.deletingLastPathComponent().path, isDirectory: item.isDirectory,
                        modified: item.modified ?? item.added, created: item.created, captured: captureDates[item.id])
        }
        result = RenameEngine.run(inputs, steps: steps, existing: existing)
        plans = zip(ordered, result.outcomes).map { RenamePlan(item: $0, newName: $1.newName) }
    }

    /// 后台读一次各个文件夹里已有的名字（判断和别的文件重名）。
    private func loadExisting() {
        let dirs = Set(items.map { $0.url.deletingLastPathComponent().path })
        Task {
            let map = await Task.detached(priority: .userInitiated) { () -> [String: Set<String>] in
                var map: [String: Set<String>] = [:]
                for dir in dirs {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                    map[dir] = Set(names.map { $0.lowercased() })
                }
                return map
            }.value
            existing = map
        }
    }

    /// 后台读照片的拍摄日期（EXIF），读完刷新预览。
    private func loadCaptureDates() {
        guard captureDates.isEmpty, !loadingCaptureDates else { return }
        loadingCaptureDates = true
        let list = items
        Task {
            let dates = await Task.detached(priority: .userInitiated) { () -> [String: Date] in
                var dates: [String: Date] = [:]
                for item in list { dates[item.id] = Renamer.captureDate(item) }
                return dates
            }.value
            loadingCaptureDates = false
            captureDates = dates
        }
    }

    private func apply() {
        guard canApply else { return }
        let outcome = Renamer.apply(plans)
        dismiss()
        if !outcome.failed.isEmpty {
            store.alertMessage = String(localized: "\(outcome.failed.count) 个文件没能改名（可能被占用或没有权限）：") + outcome.failed.prefix(5).joined(separator: String(localized: "、"))
        }
        store.renamed(outcome.done)
    }
}

extension RenameStep.Kind {
    var title: String {
        switch self {
        case .replace: return String(localized: "查找替换")
        case .sequence: return String(localized: "加序号")
        case .date: return String(localized: "加日期")
        case .affix: return String(localized: "加前缀 / 后缀")
        case .spaces: return String(localized: "空格")
        case .letterCase: return String(localized: "大小写")
        case .removeCopySuffix: return String(localized: "去掉「副本」")
        }
    }
}

/// 规则模式里的一行规则。
struct RenameStepRow: View {
    @Binding var step: RenameStep
    let number: Int
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let delete: () -> Void

    private static let dateFormats = ["yyyy-MM-dd", "yyyyMMdd", "yyyy-MM", "yyMMdd", "yyyy-MM-dd HH.mm"]

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(number)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(step.kind.title)
                .fontWeight(.medium)
                .frame(width: 92, alignment: .leading)
            fields
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(!canMoveUp)
                .help("上移")
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(!canMoveDown)
                .help("下移")
            Button { delete() } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("删除这条规则")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder
    private var fields: some View {
        switch step.kind {
        case .replace:
            HStack(spacing: 8) {
                TextField(step.useRegex ? String(localized: "查找（正则，例如 IMG_(\\d+)）") : String(localized: "查找"), text: $step.find)
                    .textFieldStyle(.roundedBorder)
                TextField(step.useRegex ? String(localized: "替换为（$1 = 第 1 个括号）") : String(localized: "替换为（留空表示删除）"), text: $step.replacement)
                    .textFieldStyle(.roundedBorder)
                Toggle("正则", isOn: $step.useRegex)
                    .toggleStyle(.checkbox)
                Toggle("区分大小写", isOn: $step.caseSensitive)
                    .toggleStyle(.checkbox)
            }
        case .sequence:
            HStack(spacing: 8) {
                positionPicker
                Stepper("起始 \(step.start)", value: $step.start, in: 0...99999)
                Stepper("步长 \(step.step)", value: $step.step, in: 1...100)
                Picker("位数", selection: $step.digits) {
                    Text(verbatim: "1").tag(1); Text(verbatim: "01").tag(2); Text(verbatim: "001").tag(3); Text(verbatim: "0001").tag(4)
                }
                .labelsHidden()
                .frame(width: 72)
                separatorField
            }
        case .date:
            HStack(spacing: 8) {
                Picker("日期", selection: $step.dateSource) {
                    Text("修改日期").tag(RenameDateSource.modified)
                    Text("创建日期").tag(RenameDateSource.created)
                    Text("拍摄日期").tag(RenameDateSource.captured)
                    Text("今天").tag(RenameDateSource.today)
                }
                .labelsHidden()
                .frame(width: 104)
                Picker("格式", selection: $step.dateFormat) {
                    ForEach(Self.dateFormats, id: \.self) { format in
                        Text(verbatim: Self.example(format)).tag(format)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                positionPicker
                separatorField
            }
        case .affix:
            HStack(spacing: 8) {
                TextField("前缀", text: $step.prefix).textFieldStyle(.roundedBorder)
                Text("原名").foregroundStyle(.secondary)
                TextField("后缀", text: $step.suffix).textFieldStyle(.roundedBorder)
            }
        case .spaces:
            Picker("空格", selection: $step.spaceReplacement) {
                Text("去掉空格").tag("")
                Text("空格换成 _").tag("_")
                Text("空格换成 -").tag("-")
                Text("空格换成 .").tag(".")
            }
            .labelsHidden()
            .frame(width: 140)
        case .letterCase:
            Picker("大小写", selection: $step.letterCase) {
                Text("全部小写").tag(RenameLetterCase.lower)
                Text("全部大写").tag(RenameLetterCase.upper)
                Text("每个词首字母大写").tag(RenameLetterCase.capitalized)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 330)
        case .removeCopySuffix:
            Text("去掉名字末尾的「副本」「 copy」「 (1)」「 2」")
                .foregroundStyle(.secondary)
        }
    }

    private var positionPicker: some View {
        Picker("位置", selection: $step.position) {
            Text("开头").tag(RenamePosition.prefix)
            Text("结尾").tag(RenamePosition.suffix)
        }
        .labelsHidden()
        .frame(width: 72)
    }

    private var separatorField: some View {
        TextField("连接符", text: $step.separator)
            .textFieldStyle(.roundedBorder)
            .frame(width: 44)
            .help("序号 / 日期和原名之间的连接符，可以留空")
    }

    private static func example(_ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: Date())
    }
}
