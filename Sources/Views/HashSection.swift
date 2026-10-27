import SwiftUI

/// 简介里的「校验值」：点一下在后台算 MD5 / SHA-1 / SHA-256（一遍读完，大文件有进度、可以取消），
/// 每个都能拷贝；「比较」里粘贴官网给的值，按长度认出算法，绿色 ✓ 一致 / 红色 ✗ 不一致。免费。
@MainActor
final class HashModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(Double)
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var hashes: [HashAlgorithm: String] = [:]
    @Published var compareText = ""
    private var task: Task<Void, Never>?
    private var worker: Task<Result<[HashAlgorithm: String], Error>, Never>?
    private var path: String?

    /// 换了一个文件：停下正在算的，清空结果（粘贴的比较值也清掉）。
    func reset(_ path: String) {
        guard path != self.path else { return }
        cancel()
        self.path = path
        hashes = [:]
        phase = .idle
        compareText = ""
    }

    func start() {
        guard let path, task == nil else { return }
        let url = URL(fileURLWithPath: path)
        phase = .running(0)
        // 读文件、算校验值都在后台；取消时同时取消这个后台任务，读完当前这一块就停。
        let worker = Task.detached(priority: .utility) { [weak self] () -> Result<[HashAlgorithm: String], Error> in
            var lastReport = Date.distantPast
            do {
                let hashes = try HashLogic.hash(url: url, progress: { done, total in
                    // 最多每 0.1 秒更新一次进度条。
                    let now = Date()
                    guard now.timeIntervalSince(lastReport) > 0.1 || done == total else { return }
                    lastReport = now
                    let fraction = total > 0 ? Double(done) / Double(total) : 0
                    Task { @MainActor in self?.progressed(fraction, path: path) }
                }, isCancelled: { Task.isCancelled })
                return .success(hashes)
            } catch {
                return .failure(error)
            }
        }
        self.worker = worker
        task = Task { [weak self] in
            let result = await worker.value
            guard let model = self, model.path == path, model.worker == worker else { return }
            model.task = nil
            model.worker = nil
            switch result {
            case .success(let hashes):
                model.hashes = hashes
                model.phase = .done
            case .failure(let error):
                if error is CancellationError {
                    model.phase = .idle
                } else {
                    model.phase = .failed(String(localized: "读不了这个文件：\(error.localizedDescription)"))
                }
            }
        }
    }

    private func progressed(_ fraction: Double, path: String) {
        guard case .running = phase, self.path == path else { return }
        phase = .running(fraction)
    }

    func cancel() {
        worker?.cancel()
        worker = nil
        task?.cancel()
        task = nil
        if case .running = phase { phase = .idle }
    }

    var comparison: HashLogic.CompareResult {
        HashLogic.compare(compareText, with: hashes)
    }
}

struct HashSection: View {
    let item: FileItem
    @StateObject private var model = HashModel()
    /// 右键 / 文件菜单「计算哈希」。
    @ObservedObject private var request = HashRequest.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("校验值")
                .font(.caption)
                .foregroundStyle(.secondary)
            switch model.phase {
            case .idle:
                Button("计算 MD5 / SHA-1 / SHA-256") { model.start() }
                    .controlSize(.small)
                    .help("下载的安装包可以和官网给的校验值对一下，确认文件完整、没被改过")
            case .running(let fraction):
                HStack(spacing: 8) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("取消") { model.cancel() }
                        .controlSize(.small)
                }
                Text("计算中…大文件在后台算，随时可以关掉简介")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("重试") { model.start() }
                    .controlSize(.small)
            case .done:
                ForEach(HashAlgorithm.allCases) { algorithm in
                    hashRow(algorithm)
                }
            }
            compareField
        }
        .task(id: item.path) {
            model.reset(item.path)
            takeRequest()
        }
        .onChange(of: request.tick) { takeRequest() }
        .onDisappear { model.cancel() }
        // 粘贴了一个像样的校验值、还没算：直接开始算，算完自动比对。
        .onChange(of: model.compareText) {
            if case .idle = model.phase, HashLogic.extract(model.compareText) != nil { model.start() }
        }
    }

    /// 「计算哈希」点的就是这个文件：开始算（已经算过 / 正在算就不重来）。
    private func takeRequest() {
        guard request.take(item.path) else { return }
        if case .idle = model.phase { model.start() }
        if case .failed = model.phase { model.start() }
    }

    private func hashRow(_ algorithm: HashAlgorithm) -> some View {
        let value = model.hashes[algorithm] ?? ""
        let matched = model.comparison == .match(algorithm)
        return HStack(spacing: 8) {
            Text(algorithm.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(HashLogic.abbreviated(value))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(matched ? Color.green : Color.primary)
                .lineLimit(1)
                .textSelection(.enabled)
                .help(value)
            Spacer(minLength: 4)
            Button("拷贝") {
                FileActions.copy(value)
                LibraryStore.shared?.showToast(String(localized: "已拷贝 \(algorithm.title)"))
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var compareField: some View {
        let result = model.comparison
        VStack(alignment: .leading, spacing: 4) {
            Text("比较")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("粘贴官网给的值", text: $model.compareText)
                .textFieldStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(borderColor(result), lineWidth: result == .empty ? 0.8 : 1.5))
            switch result {
            case .empty:
                EmptyView()
            case .match(let algorithm):
                Label("一致：和 \(algorithm.title) 相同，文件没被改过", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            case .mismatch(let algorithm):
                Label("不一致：和 \(algorithm.title) 对不上，文件可能没下载完整或被改过", systemImage: "xmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
            case .notComputed(let algorithm):
                Text("看起来是 \(algorithm.title)，算完自动比对")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unrecognized:
                Text("认不出来：MD5 是 32 位、SHA-1 是 40 位、SHA-256 是 64 位")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func borderColor(_ result: HashLogic.CompareResult) -> Color {
        switch result {
        case .match: return .green
        case .mismatch: return .red
        case .unrecognized: return .orange
        default: return Color.primary.opacity(0.15)
        }
    }
}
