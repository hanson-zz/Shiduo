import Compression
import Foundation

// 拾掇 Pro：压缩包浏览的读取和解压（在后台线程调用，不碰界面）。
// zip：自己按目录解压「不压缩」和 deflate 两种（绝大多数 zip 都是这两种），文件名用我们解出来的（GBK 名字也对）；
// 其他压缩方式交给系统的 ditto 整包解压。tar / 7z / rar：系统的 /usr/bin/tar。压缩包本身只读不改。

enum ArchiveError: Error, Equatable {
    /// 加了密码。
    case encrypted
    /// 系统读不了这个包（格式不支持或文件坏了）。
    case unreadable
    /// 解压时出错（磁盘满、没有权限……）。
    case failed(String)
}

enum ArchiveIO {
    /// 列出压缩包里的内容。
    static func list(_ url: URL) throws -> [ArchiveEntry] {
        guard let kind = ArchiveKind.kind(forName: url.lastPathComponent) else { throw ArchiveError.unreadable }
        switch kind {
        case .zip:
            do {
                return try ZipDirectoryReader.readEntries(at: url)
            } catch {
                // 改了扩展名的其他格式：再让系统 tar 试一次。
                return try bsdtarList(url)
            }
        case .tar, .other:
            return try bsdtarList(url)
        }
    }

    /// 把 entries（已经按选中的展开好）解压到 staging 里，保持压缩包里的路径（staging/a/b/c.txt）。
    /// all = true 表示整个包（tar 不用点名）。
    static func extract(_ archive: URL, entries: [ArchiveEntry], all: Bool, into staging: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        guard let kind = ArchiveKind.kind(forName: archive.lastPathComponent) else { throw ArchiveError.unreadable }
        let isRealZip = kind == .zip && entries.allSatisfy { $0.rawName == nil }
        if isRealZip {
            if entries.contains(where: { $0.isEncrypted && !$0.isDirectory }) { throw ArchiveError.encrypted }
            if entries.allSatisfy({ $0.isDirectory || $0.method == 0 || $0.method == 8 }) {
                try ZipExtractor.extract(archive, entries: entries, into: staging)
            } else {
                // 少见的压缩方式（bzip2、LZMA、deflate64……）：系统 ditto 整包解出来（只在临时文件夹里）。
                try run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
            }
            return
        }
        var args = ["-x", "-f", archive.path, "-C", staging.path]
        var listFile: URL?
        // 空文件夹自己建（点名文件夹时 tar 的匹配规则因包而异，只点名文件最稳）。
        for entry in entries where entry.isDirectory {
            try? fm.createDirectory(at: staging.appendingPathComponent(entry.path, isDirectory: true), withIntermediateDirectories: true)
        }
        let files = entries.filter { !$0.isDirectory }
        if !all {
            // 点名要解压的文件（一行一个，用 -T 读，名字再长再多也不会超过命令行长度）。
            let names = files.compactMap { $0.rawName }
            guard !names.isEmpty else { return }
            let file = fm.temporaryDirectory.appendingPathComponent("shiduo-tar-\(UUID().uuidString).txt")
            try (names.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            listFile = file
            args += ["-T", file.path]
        }
        defer { if let listFile { try? fm.removeItem(at: listFile) } }
        let result = try run("/usr/bin/tar", args, allowFailure: true)
        // 有的条目（比如符号链接）tar 报了错，但要的文件都解出来了：算成功。
        let allThere = !files.isEmpty && files.allSatisfy { entry in
            entry.isSymlink || fm.fileExists(atPath: staging.appendingPathComponent(entry.path).path)
        }
        if result.status != 0, !allThere {
            let message = String(decoding: result.err, as: UTF8.self)
            if message.lowercased().contains("passphrase") || message.lowercased().contains("encrypt") {
                throw ArchiveError.encrypted
            }
            throw ArchiveError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: 系统 tar

    static func bsdtarList(_ url: URL) throws -> [ArchiveEntry] {
        let names = try run("/usr/bin/tar", ["-t", "-f", url.path], allowFailure: true)
        guard names.status == 0 else {
            let message = String(decoding: names.err, as: UTF8.self).lowercased()
            if message.contains("passphrase") || message.contains("encrypt") { throw ArchiveError.encrypted }
            throw ArchiveError.unreadable
        }
        let verbose = (try? run("/usr/bin/tar", ["-t", "-v", "-f", url.path], allowFailure: true))?.out ?? Data()
        return BsdtarListing.parse(names: String(decoding: names.out, as: UTF8.self),
                                   verbose: String(decoding: verbose, as: UTF8.self))
    }

    /// 运行一个系统命令，读完输出。中文名字按 UTF-8 输出（LC_ALL=en_US.UTF-8，日期是英文月份，方便解析）。
    @discardableResult
    static func run(_ tool: String, _ arguments: [String], allowFailure: Bool = false) throws -> (status: Int32, out: Data, err: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["LANG"] = "en_US.UTF-8"
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ArchiveError.unreadable
        }
        // 错误输出在另一条线程上读，免得两边管道都满了互相等。
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        if !allowFailure, process.terminationStatus != 0 {
            throw ArchiveError.failed(String(decoding: errData, as: UTF8.self))
        }
        return (process.terminationStatus, outData, errData)
    }
}

/// 按 zip 目录逐个解压文件（不压缩的直接拷，deflate 用系统 Compression 框架流式解压，大文件也不占多少内存）。
enum ZipExtractor {
    static func extract(_ archive: URL, entries: [ArchiveEntry], into staging: URL) throws {
        let fm = FileManager.default
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let root = staging.resolvingSymlinksInPath().standardizedFileURL.path
        /// 写之前核对：顺着已经建好的链接解析后，目标的上一层还在解压文件夹里（防 zip-slip）。
        func insideStaging(_ url: URL) -> Bool {
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            return parent == root || parent.hasPrefix(root + "/")
        }
        for entry in entries {
            let target = staging.appendingPathComponent(entry.path, isDirectory: entry.isDirectory)
            guard insideStaging(target) else { continue }
            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard insideStaging(target) else { continue }
            try handle.seek(toOffset: entry.localHeaderOffset)
            let header = [UInt8](try handle.read(upToCount: 30) ?? Data())
            guard header.count == 30, ByteReader(header).u32(0) == ZipDirectoryReader.localSignature else {
                throw ArchiveError.unreadable
            }
            let skip = 30 + Int(ByteReader(header).u16(26)) + Int(ByteReader(header).u16(28))
            try handle.seek(toOffset: entry.localHeaderOffset + UInt64(skip))
            let packed = UInt64(max(0, entry.compressedSize ?? 0))

            if entry.isSymlink {
                // 替身 / 符号链接：内容是指向的路径。只建相对路径的（不指向压缩包外面的绝对位置）。
                var data = Data()
                try copy(handle, packed: packed, method: entry.method) { data.append($0) }
                let destination = String(decoding: data, as: UTF8.self)
                if ArchivePathLogic.symlinkStaysInside(entryPath: entry.path, destination: destination) {
                    try? fm.removeItem(at: target)
                    try? fm.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
                }
                continue
            }

            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            guard fm.createFile(atPath: target.path, contents: nil) else {
                throw ArchiveError.failed(target.path)
            }
            let output = try FileHandle(forWritingTo: target)
            do {
                try copy(handle, packed: packed, method: entry.method) { try output.write(contentsOf: $0) }
                try output.close()
            } catch {
                try? output.close()
                throw error
            }
            var attributes: [FileAttributeKey: Any] = [:]
            if let date = entry.modified { attributes[.modificationDate] = date }
            if let mode = entry.unixMode, mode & 0o777 != 0 { attributes[.posixPermissions] = Int(mode & 0o777) }
            if !attributes.isEmpty { try? fm.setAttributes(attributes, ofItemAtPath: target.path) }
        }
    }

    /// 读 packed 字节的压缩数据，解出来交给 write。
    static func copy(_ handle: FileHandle, packed: UInt64, method: UInt16, write: @escaping (Data) throws -> Void) throws {
        let chunk = 1 << 20
        var remaining = packed
        switch method {
        case 0:
            while remaining > 0 {
                guard let data = try handle.read(upToCount: Int(min(remaining, UInt64(chunk)))), !data.isEmpty else {
                    throw ArchiveError.unreadable
                }
                try write(data)
                remaining -= UInt64(data.count)
            }
        case 8:
            // COMPRESSION_ZLIB 就是 zip 里不带头的 raw deflate。
            let filter = try OutputFilter(.decompress, using: .zlib) { data in
                if let data, !data.isEmpty { try write(data) }
            }
            while remaining > 0 {
                guard let data = try handle.read(upToCount: Int(min(remaining, UInt64(chunk)))), !data.isEmpty else {
                    throw ArchiveError.unreadable
                }
                try filter.write(data)
                remaining -= UInt64(data.count)
            }
            try filter.finalize()
        default:
            throw ArchiveError.unreadable
        }
    }
}

/// 解压出来的东西放到目标文件夹：同名不覆盖，改叫「名称 2」（和拾掇的拷贝一样）。
enum ArchivePlacement {
    /// 把 staging 里的 relativePaths（压缩包里的路径）一个个移到 destination，返回放好的位置。
    static func place(_ relativePaths: [String], from staging: URL, to destination: URL) throws -> [URL] {
        let fm = FileManager.default
        var placed: [URL] = []
        for path in relativePaths {
            let source = staging.appendingPathComponent(path)
            guard fm.fileExists(atPath: source.path) || (try? fm.destinationOfSymbolicLink(atPath: source.path)) != nil else { continue }
            let name = uniqueName(source.lastPathComponent) { fm.fileExists(atPath: destination.appendingPathComponent($0).path) }
            let target = destination.appendingPathComponent(name)
            try fm.moveItem(at: source, to: target)
            placed.append(target)
        }
        return placed
    }

    /// 「图.png」→「图 2.png」→「图 3.png」；文件夹「素材」→「素材 2」。
    static func uniqueName(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !exists(candidate) { return candidate }
            n += 1
        }
    }
}
