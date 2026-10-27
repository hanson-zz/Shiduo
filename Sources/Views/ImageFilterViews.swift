import SwiftUI

extension RGBColor {
    var color: Color { Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
}

/// 列表上面筛选栏里的「图片」按钮：按尺寸、方向（横 / 竖 / 方）、主色筛（免费）。
struct ImageFilterButton: View {
    @Binding var filter: ImageFilter
    @ObservedObject private var meta = ImageMetaStore.shared
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            HStack(spacing: 5) {
                if let color = filter.color {
                    Circle().fill(color.display.color).frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                } else {
                    Image(systemName: "photo")
                }
                Text(filter.isActive ? String(localized: "图片：\(filter.summary)") : String(localized: "图片：全部"))
                if filter.isActive && meta.pending > 0 {
                    ProgressView().controlSize(.mini)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(filter.isActive ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06)))
        .help(meta.pending > 0 && filter.isActive ? String(localized: "正在分析图片尺寸和颜色，还剩 \(meta.pending) 张") : String(localized: "按尺寸、方向、颜色筛选图片"))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ImageFilterPopover(filter: $filter)
        }
    }
}

private struct ImageFilterPopover: View {
    @Binding var filter: ImageFilter
    @ObservedObject private var meta = ImageMetaStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("方向").font(.caption).foregroundStyle(.secondary)
                Picker("方向", selection: $filter.orientation) {
                    Text("不限").tag(ImageOrientation?.none)
                    ForEach(ImageOrientation.allCases) { Text($0.title).tag(ImageOrientation?.some($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("尺寸").font(.caption).foregroundStyle(.secondary)
                Picker("尺寸", selection: $filter.size) {
                    ForEach(ImageSizePreset.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                if filter.size == .custom {
                    HStack(spacing: 6) {
                        Text("宽 ≥")
                        TextField("0", value: $filter.customMinWidth, format: .number)
                            .frame(width: 70)
                        Text("高 ≥")
                        TextField("0", value: $filter.customMinHeight, format: .number)
                            .frame(width: 70)
                        Text("像素").foregroundStyle(.secondary)
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("主色").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 6), alignment: .leading, spacing: 8) {
                    ForEach(ColorSwatch.allCases) { swatch in
                        Button {
                            filter.color = filter.color == swatch ? nil : swatch
                        } label: {
                            Circle()
                                .fill(swatch.display.color)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                                .overlay {
                                    if filter.color == swatch {
                                        Circle().strokeBorder(Color.accentColor, lineWidth: 2).frame(width: 26, height: 26)
                                    }
                                }
                                .frame(width: 26, height: 26)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(swatch.title)
                    }
                }
            }
            HStack {
                if meta.pending > 0 && filter.isActive {
                    ProgressView().controlSize(.small)
                    Text("正在分析，还剩 \(meta.pending) 张")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button("清除筛选") { filter = ImageFilter() }
                    .disabled(!filter.isActive)
            }
            Text("只看图片。第一次筛选要在本机读一下每张图（会记住，下次很快）；颜色按每张图占比最大的几种颜色算。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// 简介里图片的主色：前 5 个色块 + HEX，点一下拷贝。
struct DominantColorsSection: View {
    let item: FileItem
    @State private var colors: [WeightedColor] = []

    var body: some View {
        Group {
            if !colors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("主色")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(colors, id: \.color) { entry in
                            Button {
                                FileActions.copy(entry.color.hex)
                                LibraryStore.shared?.showToast(String(localized: "已拷贝 \(entry.color.hex)"))
                            } label: {
                                VStack(spacing: 3) {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(entry.color.color)
                                        .frame(width: 34, height: 34)
                                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                                    Text(verbatim: entry.color.hex)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "点一下拷贝 \(entry.color.hex)"))
                        }
                    }
                }
            }
        }
        .task(id: ImageMetaStore.key(item)) {
            colors = []
            colors = await ImageMetaStore.shared.load(item)?.colors ?? []
        }
    }
}
