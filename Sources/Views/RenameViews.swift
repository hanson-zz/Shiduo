import OSLog
import AppKit
import CoreServices
import ImageIO
import SwiftUI

enum RenameMode: String, CaseIterable, Identifiable {
    case sequence, date, captureTime, replace, affix
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sequence: return String(localized: "名称 + 序号")
        case .date: return String(localized: "修改日期")
        case .captureTime: return String(localized: "拍摄时间")
        case .replace: return String(localized: "替换文字")
        case .affix: return String(localized: "加前缀 / 后缀")
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

    /// 两步改名（先改成临时名），避免 a→b、b→a 互相覆盖。返回成功数和失败的文件名。
    static func apply(_ plans: [RenamePlan]) -> (done: [(old: URL, new: URL)], failed: [String]) {
        let fm = FileManager.default
        var temps: [(RenamePlan, URL)] = []
        var failed: [String] = []
        for plan in plans where plan.changed {
            let tmp = plan.item.url.deletingLastPathComponent()
                .appendingPathComponent(".shiduo-rename-\(UUID().uuidString)")
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
}

struct RenameSheet: View {
    @EnvironmentObject private var store: LibraryStore
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(items.count > 1 ? String(localized: "批量重命名 \(items.count) 个文件") : String(localized: "重命名"))
                .font(.title2.bold())
            Picker("方式", selection: $mode) {
                ForEach(RenameMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            options
                .frame(minHeight: 64, alignment: .top)

            Text("预览")
                .font(.headline)
            List(plans) { plan in
                HStack(spacing: 8) {
                    Text(plan.item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)
                    Text(plan.newName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .fontWeight(plan.changed ? .semibold : .regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: 220)

            HStack {
                Text("\(plans.filter(\.changed).count) 个文件会改名，扩展名保持不变")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("重命名") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!plans.contains(where: \.changed))
            }
        }
        .padding(22)
        .frame(width: 640, height: 560)
        .onAppear(perform: refresh)
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
    }

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
        plans = Renamer.plan(
            items, mode: mode, base: base, start: start, digits: digits,
            dateFormat: mode == .captureTime ? captureFormat : dateFormat,
            find: find, replace: replace, prefix: prefix, suffix: suffix
        )
    }

    private func apply() {
        let outcome = Renamer.apply(plans)
        dismiss()
        if !outcome.failed.isEmpty {
            store.alertMessage = String(localized: "\(outcome.failed.count) 个文件没能改名（可能被占用或没有权限）：") + outcome.failed.prefix(5).joined(separator: String(localized: "、"))
        }
        store.showToast(String(localized: "已重命名 \(outcome.done.count) 个文件"))
        store.reload()
    }
}
