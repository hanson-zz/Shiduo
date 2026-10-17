import AppKit
import SwiftUI

// MARK: - 图片工具 · 标注页

struct AnnotatePanel: View {
    @EnvironmentObject private var studio: ImageStudio

    var body: some View {
        if studio.items.isEmpty {
            ImageStudioDropZone()
        } else if let item = studio.items.first(where: { $0.id == studio.selection }) ?? studio.items.first {
            HStack(spacing: 0) {
                AnnotateCanvas(item: item, editor: studio.marker)
                Divider()
                AnnotateInspector(item: item, editor: studio.marker)
                    .frame(width: 280)
            }
        }
    }
}

// MARK: 画布

struct AnnotateCanvas: View {
    let item: ImageStudio.Item
    @ObservedObject var editor: MarkEditor
    @EnvironmentObject private var studio: ImageStudio

    private enum DragState {
        case idle
        case drawing(Mark, before: [Mark])
        case moving(Mark, before: [Mark])
    }

    @State private var drag: DragState?

    var body: some View {
        GeometryReader { geo in
            let fit = fitted(item.originalSize, in: CGSize(width: geo.size.width - 48, height: geo.size.height - 48))
            let scale = fit.width / max(item.originalSize.width, 1)
            let marks = editor.list(item.id)
            let effects: (pixelated: CGImage?, blurred: CGImage?) = marks.contains { $0.kind == .mosaic && $0.mosaic != .solid } || drawingMosaic
                ? editor.previewEffects(for: item) : (pixelated: nil, blurred: nil)
            let renderer = MarkRenderer(base: item.preview, imageSize: item.originalSize,
                                        pixelated: effects.pixelated, blurred: effects.blurred)
            ZStack(alignment: .topLeading) {
                CheckerboardBackground()
                Canvas { context, _ in
                    context.withCGContext { cg in renderer.draw(marks, in: cg, scale: scale) }
                }
                if let selected = marks.first(where: { $0.id == editor.selected }) {
                    let b = selected.bounds
                    Rectangle()
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(width: max(b.width * scale, 6) + 10, height: max(b.height * scale, 6) + 10)
                        .offset(x: b.minX * scale - 5, y: b.minY * scale - 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: fit.width, height: fit.height)
            .clipShape(Rectangle())
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .contentShape(Rectangle())
            .gesture(gesture(scale: scale))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .onDeleteCommand { editor.deleteSelected(item.id) }
    }

    private var drawingMosaic: Bool {
        if case .drawing(let mark, _) = drag { return mark.kind == .mosaic }
        return editor.tool == .mosaic
    }

    private func fitted(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return CGSize(width: 1, height: 1) }
        let s = min(box.width / size.width, box.height / size.height, 4)
        return CGSize(width: max(1, size.width * s), height: max(1, size.height * s))
    }

    private func gesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = point(value.startLocation, scale)
                let p = point(value.location, scale)
                if drag == nil { begin(at: start, scale: scale) }
                update(start: start, to: p)
            }
            .onEnded { value in
                finish(start: point(value.startLocation, scale), at: point(value.location, scale), scale: scale)
                drag = nil
            }
    }

    private func point(_ p: CGPoint, _ scale: CGFloat) -> CGPoint {
        let x = min(max(p.x / scale, 0), item.originalSize.width)
        let y = min(max(p.y / scale, 0), item.originalSize.height)
        return CGPoint(x: x, y: y)
    }

    private var shift: Bool { NSEvent.modifierFlags.contains(.shift) }

    private func kind(for tool: MarkTool) -> Mark.Kind? {
        switch tool {
        case .select: return nil
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .arrow: return .arrow
        case .pen: return .pen
        case .text: return .text
        case .step: return .step
        case .mosaic: return .mosaic
        }
    }

    private func begin(at start: CGPoint, scale: CGFloat) {
        let list = editor.list(item.id)
        let tolerance = 6 / max(scale, 0.01)
        if editor.tool != .pen, let hit = AnnotateLogic.topHit(list, at: start, tolerance: tolerance),
           let mark = list.first(where: { $0.id == hit }) {
            editor.selected = hit
            editor.adopt(mark)
            drag = .moving(mark, before: list)
            return
        }
        guard let kind = kind(for: editor.tool) else {
            editor.selected = nil
            drag = .idle
            return
        }
        var mark = Mark(kind: kind)
        mark.color = editor.color
        mark.width = editor.width(for: kind, imageSize: item.originalSize)
        mark.filled = kind == .text || kind == .rect || kind == .ellipse ? editor.filled : false
        mark.mosaic = editor.mosaicStyle
        mark.start = start
        mark.end = start
        mark.points = [start]
        mark.rect = CGRect(origin: start, size: .zero)
        editor.selected = nil
        drag = .drawing(mark, before: list)
    }

    private func update(start: CGPoint, to p: CGPoint) {
        guard let drag else { return }
        switch drag {
        case .idle:
            return
        case .moving(let original, let before):
            let moved = original.moved(by: CGSize(width: p.x - start.x, height: p.y - start.y))
            editor.setLive(item.id, before.map { $0.id == original.id ? moved : $0 })
        case .drawing(var mark, let before):
            switch mark.kind {
            case .rect, .ellipse, .mosaic:
                mark.rect = AnnotateLogic.rect(from: start, to: p, square: shift && mark.kind != .mosaic)
            case .arrow:
                mark.end = shift ? AnnotateLogic.snapped(p, from: start) : p
            case .pen:
                if let last = mark.points.last, hypot(last.x - p.x, last.y - p.y) >= mark.width * 0.4 {
                    mark.points.append(p)
                }
            case .text, .step:
                return
            }
            self.drag = .drawing(mark, before: before)
            editor.setLive(item.id, before + [mark])
        }
    }

    private func finish(start: CGPoint, at p: CGPoint, scale: CGFloat) {
        guard let drag else { return }
        let tiny = 4 / max(scale, 0.01)
        switch drag {
        case .idle:
            return
        case .moving(let original, let before):
            if hypot(p.x - start.x, p.y - start.y) < 0.5 {
                editor.setLive(item.id, before)
            } else {
                let moved = original.moved(by: CGSize(width: p.x - start.x, height: p.y - start.y))
                editor.commit(item.id, before.map { $0.id == original.id ? moved : $0 }, from: before)
            }
        case .drawing(var mark, let before):
            switch mark.kind {
            case .rect, .ellipse, .mosaic:
                guard mark.rect.width >= tiny, mark.rect.height >= tiny else {
                    editor.setLive(item.id, before)
                    return
                }
            case .arrow:
                guard hypot(mark.end.x - mark.start.x, mark.end.y - mark.start.y) >= tiny * 2 else {
                    editor.setLive(item.id, before)
                    return
                }
            case .pen:
                break
            case .step:
                let d = mark.width
                mark.number = AnnotateLogic.nextStepNumber(before)
                mark.rect = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
            case .text:
                mark.text = String(localized: "文字")
                mark.rect.origin = p
                MarkEditor.fitText(&mark)
                mark.rect.origin.y = max(0, p.y - mark.rect.height / 2)
            }
            editor.commit(item.id, before + [mark], from: before)
            editor.selected = mark.id
            if mark.kind == .text { editor.focusTextTick += 1 }
        }
    }
}

// MARK: 右边的设置

struct AnnotateInspector: View {
    let item: ImageStudio.Item
    @ObservedObject var editor: MarkEditor
    @EnvironmentObject private var studio: ImageStudio
    @FocusState private var textFocused: Bool

    private var selectedMark: Mark? {
        editor.list(item.id).first { $0.id == editor.selected }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    tools
                    style
                    if let mark = selectedMark, mark.kind == .text { textField(mark) }
                    redaction
                    edit
                }
                .padding(16)
            }
            Divider()
            actions.padding(14)
        }
        .onChange(of: editor.focusTextTick) { textFocused = true }
    }

    private var tools: some View {
        section("工具") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(MarkTool.allCases) { tool in
                    Button {
                        editor.tool = tool
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tool.symbol).font(.system(size: 15))
                            Text(tool.title).font(.caption2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(editor.tool == tool ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .foregroundStyle(editor.tool == tool ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("拖动画框、箭头、马赛克，单击放文字和序号；按住 ⇧ 画正方形或 45° 箭头。点中已有的标注可以拖动，按 ⌫ 删除。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var style: some View {
        let kind = selectedMark?.kind
        let showMosaic = editor.tool == .mosaic || kind == .mosaic
        section("样式") {
            if !(kind == .mosaic) {
                HStack(spacing: 7) {
                    ForEach(MarkColor.palette, id: \.self) { color in
                        Button {
                            editor.color = color
                            editor.updateSelected(item.id) { if $0.kind != .mosaic { $0.color = color } }
                        } label: {
                            Circle()
                                .fill(Color(cgColor: color.cgColor))
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: editor.color == color ? 2.5 : 0).padding(-3))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
                HStack {
                    Text("粗细 / 字号")
                    Slider(value: $editor.strokeScale, in: 0.4...3)
                        .onChange(of: editor.strokeScale) { applyWidth() }
                }
                Toggle("填充 / 文字底色", isOn: $editor.filled)
                    .onChange(of: editor.filled) {
                        let filled = editor.filled
                        editor.updateSelected(item.id) { if [.rect, .ellipse, .text].contains($0.kind) { $0.filled = filled } }
                    }
            }
            if showMosaic {
                Picker("马赛克", selection: $editor.mosaicStyle) {
                    ForEach(MosaicStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: editor.mosaicStyle) {
                    let style = editor.mosaicStyle
                    editor.updateSelected(item.id) { if $0.kind == .mosaic { $0.mosaic = style } }
                }
                if editor.mosaicStyle != .solid {
                    HStack {
                        Text("强度")
                        Slider(value: $editor.mosaicStrength, in: 0.5...3)
                    }
                }
            }
        }
    }

    private func applyWidth() {
        let size = item.originalSize
        editor.updateSelected(item.id) { mark in
            guard mark.kind != .mosaic else { return }
            let w = editor.width(for: mark.kind, imageSize: size)
            if mark.kind == .step {
                let center = CGPoint(x: mark.rect.midX, y: mark.rect.midY)
                mark.rect = CGRect(x: center.x - w / 2, y: center.y - w / 2, width: w, height: w)
            }
            mark.width = w
        }
    }

    private func textField(_ mark: Mark) -> some View {
        section("文字内容") {
            TextField("输入文字", text: Binding(
                get: { mark.text },
                set: { new in editor.updateSelected(item.id) { $0.text = new } }
            ), axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .focused($textFocused)
        }
    }

    private var redaction: some View {
        section("自动打码") {
            Text("在本机识别，不联网。认出来的地方加上马赛克，可以再拖动或删掉。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 4) {
                ForEach(SensitiveKind.allCases) { kind in
                    Toggle(kind.title, isOn: Binding(
                        get: { editor.redactKinds.contains(kind) },
                        set: { on in
                            if on { editor.redactKinds.insert(kind) } else { editor.redactKinds.remove(kind) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            HStack {
                Button {
                    editor.redact(item, studio: studio)
                } label: {
                    Label("自动打码", systemImage: "eye.slash")
                }
                .disabled(editor.redacting)
                if editor.redacting { ProgressView().controlSize(.small) }
            }
        }
    }

    private var edit: some View {
        section("编辑") {
            HStack {
                Button {
                    editor.undo(item.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!editor.canUndo(item.id))
                .help("撤销")
                Button {
                    editor.redo(item.id)
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!editor.canRedo(item.id))
                .help("重做")
                Button("删除选中") { editor.deleteSelected(item.id) }
                    .disabled(editor.selected == nil)
                Spacer()
                Button("清空", role: .destructive) { editor.clear(item.id) }
                    .disabled(editor.list(item.id).isEmpty)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    Task {
                        if let url = await editor.save(item, studio: studio) {
                            studio.show(String(localized: "已保存「\(url.lastPathComponent)」，在原图旁边"))
                        }
                    }
                } label: {
                    Text("存到原图旁边").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                Button("拷贝") { editor.copy(item, studio: studio) }
            }
            Button {
                Task {
                    if let url = await editor.save(item, studio: studio) {
                        let old = item.id
                        studio.replace(old, with: url)
                        editor.forget(old)
                        studio.mode = .beautify
                    }
                }
            } label: {
                Text("保存并接着美化").frame(maxWidth: .infinity)
            }
            Text("原图不会改动，标注图存成新文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(editor.saving)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}
