import AppKit
import SwiftUI

/// 一个接在 Mac 上的外接磁盘（移动硬盘、U 盘、SD 卡……）。
struct ExternalVolume: Identifiable, Hashable {
    let path: String
    let name: String
    let totalBytes: Int64
    let availableBytes: Int64
    let isEjectable: Bool
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// 列出外接磁盘，插拔时自动刷新（NSWorkspace didMount / didUnmount）。
@MainActor
final class VolumeMonitor: ObservableObject {
    @Published private(set) var volumes: [ExternalVolume] = []
    private var observers: [NSObjectProtocol] = []
    /// 每次刷新完调用（LibraryStore 用来在磁盘被拔掉时离开那一页）。
    var onChange: (@MainActor ([ExternalVolume]) -> Void)?

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // queue 是 .main，所以这里已经在主线程上。
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append(token)
        }
    }

    func volume(at path: String) -> ExternalVolume? {
        volumes.first { $0.path == path }
    }

    func refresh() {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeLocalizedNameKey, .volumeIsRemovableKey, .volumeIsInternalKey,
            .volumeIsEjectableKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) ?? []
        volumes = urls.compactMap { url -> ExternalVolume? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            if v.volumeIsRootFileSystem == true || v.volumeIsBrowsable == false { return nil }
            let external = v.volumeIsRemovable == true || v.volumeIsEjectable == true || v.volumeIsInternal == false
            guard external else { return nil }
            // 系统自己挂载的卷（/System/Volumes/…）不算。
            if url.path.hasPrefix("/System/") { return nil }
            return ExternalVolume(
                path: url.path,
                name: v.volumeLocalizedName ?? v.volumeName ?? url.lastPathComponent,
                totalBytes: Int64(v.volumeTotalCapacity ?? 0),
                availableBytes: Int64(v.volumeAvailableCapacity ?? 0),
                isEjectable: v.volumeIsEjectable == true || v.volumeIsRemovable == true
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        onChange?(volumes)
    }

    /// 推出磁盘。失败时返回中文原因。
    func eject(_ volume: ExternalVolume) -> String? {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
            refresh()
            return nil
        } catch {
            return String(localized: "无法推出「\(volume.name)」：可能还有 App 正在使用上面的文件。")
        }
    }
}

/// 侧边栏里的「外接磁盘」一节。没有接外接磁盘时整节隐藏。
struct VolumesSidebarSection: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var monitor: VolumeMonitor
    @EnvironmentObject private var license: LicenseManager

    var body: some View {
        if !monitor.volumes.isEmpty {
            CollapsibleSection("volumes") {
                ForEach(monitor.volumes) { volume in
                    HStack {
                        Label {
                            Text(volume.name)
                        } icon: {
                            BadgeIcon(symbol: "externaldrive.fill",
                                      colors: [Color(red: 0.62, green: 0.66, blue: 0.74), Color(red: 0.42, green: 0.46, blue: 0.55)])
                        }
                        Spacer()
                        if !license.isPro { ProBadge() }
                        if volume.isEjectable {
                            // 跟访达侧边栏一样，名字右边一个小小的推出按钮
                            Button {
                                eject(volume)
                            } label: {
                                Image(systemName: "eject.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "推出「\(volume.name)」"))
                        }
                    }
                    .help("\(volume.path) · 可用 \(volume.availableBytes.byteText)")
                    .tag(SidebarItem.volume(volume.path))
                    .simultaneousGesture(TapGesture().onEnded { store.reselect(.volume(volume.path)) })
                    .contextMenu {
                        Button("在访达中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([volume.url])
                        }
                        if volume.isEjectable {
                            Button("推出") { eject(volume) }
                        }
                    }
                }
            } header: {
                Text("外接磁盘")
            }
        }
    }

    private func eject(_ volume: ExternalVolume) {
        // 推出成功后 monitor.refresh() 会通知 LibraryStore 离开那一页；推不出去就留在原地。
        if let message = monitor.eject(volume) {
            store.alertMessage = message
        } else {
            store.showToast(String(localized: "已推出「\(volume.name)」"))
        }
    }
}
