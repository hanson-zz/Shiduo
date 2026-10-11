import Foundation
import ImageIO
import Vision

enum OCRError: Error {
    case unreadable
}

/// 用 Vision 在本机识别图片中的文字（简体中文、繁体中文、英文）。
enum OCRService {
    static func recognize(url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) { () throws -> String in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw OCRError.unreadable }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }
}

/// 识别结果的本地缓存（保存在“应用程序支持”目录，从不上传）。
@MainActor
final class OCRStore: ObservableObject {
    @Published private(set) var texts: [String: String] = [:]
    @Published var batchProgress: Double?
    @Published var batchStatus = ""

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Shiduo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ocr-cache.json")
    }()

    private var batchTask: Task<Void, Never>?

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            texts = decoded
        }
    }

    private func key(_ item: FileItem) -> String {
        item.path + "|" + String(Int(item.modified?.timeIntervalSince1970 ?? 0))
    }

    func text(for item: FileItem) -> String? {
        texts[key(item)]
    }

    /// 缓存里包含这段文字的文件路径。
    func paths(matching needle: String) -> [String] {
        // 每个词都出现即可；“wifi”也能匹配“Wi-Fi”。
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "-", with: "") }
        let words = needle.split(separator: " ").map { norm(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        return texts.compactMap { key, value in
            let text = norm(value)
            return words.allSatisfy { text.contains($0) } ? String(key.split(separator: "|").first ?? "") : nil
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(texts) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    @discardableResult
    func recognize(_ item: FileItem, persist: Bool = true) async -> String {
        if let cached = text(for: item) { return cached }
        let text = (try? await OCRService.recognize(url: item.url)) ?? ""
        texts[key(item)] = text
        if persist { save() }
        return text
    }

    func recognizeAll(_ items: [FileItem]) {
        batchTask?.cancel()
        let todo = Array(items.filter { $0.isImage && text(for: $0) == nil && FileActions.isLocal($0.url) }.prefix(500))
        guard !todo.isEmpty else {
            batchStatus = "这些图片都已经识别过了"
            return
        }
        batchTask = Task {
            for (index, item) in todo.enumerated() {
                if Task.isCancelled { break }
                batchStatus = "正在识别 \(index + 1) / \(todo.count)"
                batchProgress = Double(index) / Double(todo.count)
                await recognize(item, persist: false)
            }
            save()
            batchProgress = nil
            batchStatus = "已识别 \(todo.count) 张图片"
        }
    }

    /// 是否在后台自动识别截图和近期照片（默认开启）。
    static var autoEnabled: Bool {
        UserDefaults.standard.object(forKey: "autoOCR") as? Bool ?? true
    }

    @Published private(set) var autoRunning = false
    private var autoTask: Task<Void, Never>?

    /// 后台慢慢识别截图和近期照片，之后搜索就能搜到图里的字。
    func autoRecognize(_ items: [FileItem], limit: Int = 400) {
        guard Self.autoEnabled, autoTask == nil else { return }
        var seen = Set<String>()
        let todo = items.filter { item in
            guard item.isImage, text(for: item) == nil, seen.insert(item.path).inserted else { return false }
            return FileActions.isLocal(item.url)
        }.prefix(limit)
        guard !todo.isEmpty else { return }
        autoRunning = true
        autoTask = Task(priority: .background) {
            var count = 0
            for item in todo {
                if Task.isCancelled { break }
                await recognize(item, persist: false)
                count += 1
                if count % 20 == 0 { save() }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            save()
            autoRunning = false
            autoTask = nil
        }
    }

    func cancelBatch() {
        batchTask?.cancel()
        batchProgress = nil
        batchStatus = ""
        save()
    }

    func clearCache() {
        texts = [:]
        save()
    }
}
