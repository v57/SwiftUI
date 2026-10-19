// Foundation file APIs Apple platforms have and swift-corelibs-foundation lacks. Built on non-Apple platforms only.
#if !canImport(ObjectiveC)
import Foundation

#if os(Windows)
import WinSDK
#endif

extension URL {
    /// Apple's sandbox access to a URL the user picked; off Apple platforms there is no sandbox to ask.
    public func startAccessingSecurityScopedResource() -> Bool { true }
    public func stopAccessingSecurityScopedResource() {}
}

extension FileManager {
    /// Moves an item to the Trash (the Recycle Bin on Windows; the freedesktop.org trash elsewhere).
    public func trashItem(at url: URL, resultingItemURL outResultingURL: UnsafeMutablePointer<NSURL?>?) throws {
        #if os(Windows)
        // SHFileOperation takes a list of paths ending in two NULs.
        let path = url.path.replacingOccurrences(of: "/", with: "\\")
        var from = Array(path.utf16) + [0, 0]
        let status = from.withUnsafeMutableBufferPointer { buffer -> Int32 in
            var operation = SHFILEOPSTRUCTW()
            operation.wFunc = UINT(FO_DELETE)
            operation.pFrom = UnsafePointer(buffer.baseAddress)
            operation.fFlags = FILEOP_FLAGS(FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI)
            return SHFileOperationW(&operation)
        }
        guard status == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path, "SHFileOperation": status])
        }
        outResultingURL?.pointee = nil
        #else
        let home = homeDirectoryForCurrentUser
        let trash = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/share")
        let files = trash.appendingPathComponent("Trash/files", isDirectory: true)
        let info = trash.appendingPathComponent("Trash/info", isDirectory: true)
        try createDirectory(at: files, withIntermediateDirectories: true)
        try createDirectory(at: info, withIntermediateDirectories: true)
        var target = files.appendingPathComponent(url.lastPathComponent)
        var number = 2
        while fileExists(atPath: target.path) {
            target = files.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(number)")
                .appendingPathExtension(url.pathExtension)
            number += 1
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        try "[Trash Info]\nPath=\(url.path)\nDeletionDate=\(stamp)\n".write(
            to: info.appendingPathComponent(target.lastPathComponent + ".trashinfo"), atomically: true, encoding: .utf8)
        try moveItem(at: url, to: target)
        outResultingURL?.pointee = target as NSURL
        #endif
    }
}
#endif
