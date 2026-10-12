import Combine
import Foundation
import ImageIO
import Vision

/// 用 Vision 在本机识别照片画面里有什么（猫、海边、收据……）。不联网。
enum PhotoClassifier {
    /// 置信度高于这个值的分类才记下来。
    static let minConfidence: Float = 0.3

    static func classify(url: URL) async throws -> [String] {
        try await Task.detached(priority: .background) { () throws -> [String] in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw OCRError.unreadable }
            // 缩到 512 像素再识别，快很多，结果几乎一样。
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw OCRError.unreadable }
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            let observations = request.results ?? []
            return observations
                .filter { $0.confidence > PhotoClassifier.minConfidence }
                .map { $0.identifier }
        }.value
    }
}

/// 画面识别结果的本地缓存（应用程序支持/Shiduo/photo-labels.json），键是 路径|修改时间。
@MainActor
final class PhotoContentStore: ObservableObject {
    @Published private(set) var labels: [String: [String]] = [:]
    @Published private(set) var isRunning = false

    /// 最多分析多少张最近的图片。
    nonisolated static let limit = 2000

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Shiduo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("photo-labels.json")
    }()

    private var task: Task<Void, Never>?

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            labels = decoded
        }
    }

    private func key(_ item: FileItem) -> String {
        item.path + "|" + String(Int(item.modified?.timeIntervalSince1970 ?? 0))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(labels) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 缓存里画面符合这个概念的图片路径。
    func paths(matching concept: PhotoConcept) -> [String] {
        labels.compactMap { key, ids in
            PhotoConcepts.matches(labels: ids, concept: concept) ? String(key.split(separator: "|").first ?? "") : nil
        }
        .filter { !$0.isEmpty }
    }

    /// 后台慢慢分析最近的图片（只在 Pro 时调用）。已经分析过、只在云端的图片会跳过。
    func autoClassify(_ items: [FileItem]) {
        guard task == nil else { return }
        var seen = Set<String>()
        let todo = items.filter { item in
            guard item.isImage, labels[key(item)] == nil, seen.insert(item.path).inserted else { return false }
            return FileActions.isLocal(item.url)
        }.prefix(Self.limit)
        guard !todo.isEmpty else { return }
        isRunning = true
        task = Task(priority: .background) {
            var count = 0
            for item in todo {
                if Task.isCancelled { break }
                let ids = (try? await PhotoClassifier.classify(url: item.url)) ?? []
                labels[key(item)] = ids
                count += 1
                if count % 25 == 0 { save() }
                // 慢一点，别抢前台的 CPU。
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            save()
            isRunning = false
            task = nil
        }
    }

    func clearCache() {
        task?.cancel()
        task = nil
        isRunning = false
        labels = [:]
        save()
    }
}
