import AppKit
import Foundation
import PDFKit
import Vision

/// 从图片（Vision 文字识别）和 PDF（PDFKit，扫描件再用 Vision）里取出文字。
enum TextExtractor {
    static func canExtract(_ item: FileItem) -> Bool {
        item.isImage || item.ext == "pdf"
    }

    static func pdfText(_ url: URL) async -> String {
        await Task.detached(priority: .userInitiated) { () -> String in
            guard let doc = PDFDocument(url: url) else { return "" }
            let text = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
            // 扫描件：把前几页渲染成图片再识别。
            var pages: [String] = []
            for index in 0..<min(doc.pageCount, 5) {
                guard let page = doc.page(at: index) else { continue }
                let image = page.thumbnail(of: CGSize(width: 1600, height: 2200), for: .mediaBox)
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                pages.append(lines.joined(separator: "\n"))
            }
            return pages.joined(separator: "\n\n")
        }.value
    }
}
