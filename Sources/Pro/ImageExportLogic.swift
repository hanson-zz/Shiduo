import CoreGraphics
import Foundation

// MARK: - 图片导出的色彩和位深：纯逻辑（单元测试直接调用）

/// 导出时沿用原图的色彩空间（Display P3 等）和位深（16-bit），不再一律压成 8-bit sRGB。
/// 真正建画布、编码、写文件在 ImageExport（App 里），这里只做判断。
enum ImageExportLogic {
    /// 输出用哪个色彩空间。
    enum SpaceChoice: Equatable {
        /// 原图自己的（RGB 模型、能当输出的，比如 Display P3、Adobe RGB、sRGB、嵌入的 ICC）
        case source
        case sRGB
        /// 原图不是 RGB（CMYK、灰度、Lab、索引色）或者它的空间不能当输出：用 P3，装得下原来的颜色
        case displayP3
    }

    /// 「设备 RGB」没有描述文件，写进文件里各台 Mac 显示不一样，当作 sRGB。
    static let deviceRGBName = "kCGColorSpaceDeviceRGB"

    static func spaceChoice(model: CGColorSpaceModel, name: String?, supportsOutput: Bool) -> SpaceChoice {
        guard model == .rgb, supportsOutput else { return .displayP3 }
        if name == deviceRGBName { return .sRGB }
        return .source
    }

    /// 画布每个分量的位数：原图超过 8 位（16-bit、浮点）就用 16 位，否则 8 位。
    static func canvasBits(sourceBits: Int) -> Int {
        sourceBits > 8 ? 16 : 8
    }

    /// 写文件时的位数：PNG（和 TIFF）保留 16 位；JPEG / HEIC 一律 8 位。
    static func fileBits(canvasBits: Int, keepsDepth: Bool) -> Int {
        keepsDepth && canvasBits > 8 ? 16 : 8
    }

    /// 多张图合成一张（拼图）：任何一张超过 8 位就用 16 位。
    static func mergedBits(_ bits: [Int]) -> Int {
        canvasBits(sourceBits: bits.max() ?? 8)
    }

    /// 多张图的色彩空间都一样时沿用；不一样（或者一张都没有）返回 nil，调用方改用 Display P3（装得下 sRGB 和 P3）。
    static func common<T: Equatable>(_ values: [T]) -> T? {
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// 不覆盖地写文件：先按 url 写（write 必须用「已存在就失败」的方式），目标已存在就换 next 给的名字再试。
    /// 用来堵住「先算一个不重名的名字、再写」之间被别人抢先占用的窗口。
    static func writeAvoidingExisting(_ url: URL, attempts: Int = 20, next: (URL) -> URL,
                                      isExists: (Error) -> Bool, write: (URL) throws -> Void) throws -> URL {
        var target = url
        var lastError: Error?
        for _ in 0..<max(attempts, 1) {
            do {
                try write(target)
                return target
            } catch {
                guard isExists(error) else { throw error }
                lastError = error
                target = next(target)
            }
        }
        throw lastError ?? CocoaError(.fileWriteFileExists)
    }
}
