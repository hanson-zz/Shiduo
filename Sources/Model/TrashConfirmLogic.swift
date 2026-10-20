import Foundation

/// 什么时候「移到废纸篓」要先确认（纯逻辑，单元测试覆盖）。
/// 普通的移到废纸篓都不确认：直接移、小提示上可以撤销，30 天内还能在「清理记录」里放回。
/// 只有一次移很多（100 个以上，或者加起来 5 GB 以上）才先问一句；「立即删除」不能撤销，另外总是确认。
enum TrashConfirm {
    static let countThreshold = 100
    static let bytesThreshold: Int64 = 5 * 1_000_000_000

    /// unknownFolderSize：里面有还没算出大小的文件夹（文件夹的 size 是 0，可能有几十 GB）——也先确认，不在主线程现算。
    static func needsConfirm(count: Int, bytes: Int64, unknownFolderSize: Bool = false) -> Bool {
        count >= countThreshold || bytes >= bytesThreshold || unknownFolderSize
    }
}
