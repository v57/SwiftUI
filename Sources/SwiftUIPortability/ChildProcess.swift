// A child process for Windows that inherits only its own standard handles. Foundation's `Process` there lets
// every child inherit every inheritable handle of the app (other children's pipes, files the C runtime opened):
// running processes side by side, one child keeps another's pipe open (no end of output until it exits) or a file
// the app is replacing (a sharing violation). Built on Windows only.
#if os(Windows)
import Foundation
import WinSDK

public final class ChildProcess: @unchecked Sendable {
    public enum Stream: Sendable { case output, error }

    private let process: HANDLE
    private let output: HANDLE
    private let error: HANDLE
    private var input: HANDLE?
    private let lock = NSLock()
    private var exited = false

    /// Starts `executable` with `arguments` in `directory`. `environment` replaces the app's; with `input` the
    /// child's standard input is a pipe (`write`, `closeInput`), else NUL.
    public init(executable: URL, arguments: [String], directory: URL?, environment: [String: String], input: Bool = false) throws {
        var security = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: nil, bInheritHandle: true)
        func pipe() throws -> (read: HANDLE, write: HANDLE) {
            var read: HANDLE?, write: HANDLE?
            guard CreatePipe(&read, &write, &security, 0), let read, let write else { throw Self.lastError("CreatePipe") }
            return (read, write)
        }
        let out = try pipe(), err = try pipe()
        // The app's ends stay with the app.
        SetHandleInformation(out.read, DWORD(HANDLE_FLAG_INHERIT), 0)
        SetHandleInformation(err.read, DWORD(HANDLE_FLAG_INHERIT), 0)
        var childInput: HANDLE
        if input {
            let pipe = try pipe()
            SetHandleInformation(pipe.write, DWORD(HANDLE_FLAG_INHERIT), 0)
            childInput = pipe.read
            self.input = pipe.write
        } else {
            guard let nul = "NUL".withCString(encodedAs: UTF16.self, {
                CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), &security, DWORD(OPEN_EXISTING), 0, nil)
            }), nul != INVALID_HANDLE_VALUE else { throw Self.lastError("NUL") }
            childInput = nul
        }
        defer {
            CloseHandle(childInput)
            CloseHandle(out.write)
            CloseHandle(err.write)
        }

        // Only these three handles go to the child.
        var inherited: [HANDLE?] = [childInput, out.write, err.write]
        var size: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &size)
        let attributes = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { attributes.deallocate() }
        let list = OpaquePointer(attributes)
        guard InitializeProcThreadAttributeList(list, 1, 0, &size) else { throw Self.lastError("InitializeProcThreadAttributeList") }
        defer { DeleteProcThreadAttributeList(list) }
        let updated = inherited.withUnsafeMutableBufferPointer { handles in
            UpdateProcThreadAttribute(
                list, 0, Self.handleListAttribute, handles.baseAddress,
                SIZE_T(MemoryLayout<HANDLE?>.stride * handles.count), nil, nil)
        }
        guard updated else { throw Self.lastError("UpdateProcThreadAttribute") }

        var startup = STARTUPINFOEXW()
        startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        startup.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
        startup.StartupInfo.hStdInput = childInput
        startup.StartupInfo.hStdOutput = out.write
        startup.StartupInfo.hStdError = err.write
        startup.lpAttributeList = list

        var commandLine = Array(([executable.path] + arguments).map(Self.quote).joined(separator: " ").utf16) + [0]
        let block = environment.sorted { $0.key.uppercased() < $1.key.uppercased() }.map { "\($0.key)=\($0.value)" }
        var environmentBlock = Array((block.joined(separator: "\0") + "\0\0").utf16)
        var info = PROCESS_INFORMATION()
        let flags = DWORD(CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW)
        let created = executable.path.withCString(encodedAs: UTF16.self) { application in
            (directory?.path ?? FileManager.default.currentDirectoryPath).withCString(encodedAs: UTF16.self) { cwd in
                environmentBlock.withUnsafeMutableBufferPointer { env in
                    withUnsafeMutablePointer(to: &startup.StartupInfo) { startupInfo in
                        CreateProcessW(application, &commandLine, nil, nil, true, flags, env.baseAddress, cwd, startupInfo, &info)
                    }
                }
            }
        }
        guard created else {
            CloseHandle(out.read)
            CloseHandle(err.read)
            if let input = self.input { CloseHandle(input) }
            throw Self.lastError("CreateProcess \(executable.path)")
        }
        CloseHandle(info.hThread)
        process = info.hProcess
        output = out.read
        error = err.read
    }

    deinit {
        CloseHandle(process)
        CloseHandle(output)
        CloseHandle(error)
        if let input { CloseHandle(input) }
    }

    /// Reads a stream until the child closes it, handing on each chunk (blocking: call it on its own thread).
    public func read(_ stream: Stream, chunk: (Data) -> Void) {
        let handle = stream == .output ? output : error
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var count: DWORD = 0
            let ok = buffer.withUnsafeMutableBytes { ReadFile(handle, $0.baseAddress, DWORD($0.count), &count, nil) }
            guard ok, count > 0 else { return }
            chunk(Data(buffer[0..<Int(count)]))
        }
    }

    /// Writes to the child's standard input (a pipe when made with `input`).
    public func write(_ data: Data) {
        guard let input = lock.withLock({ self.input }) else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                var written: DWORD = 0
                guard WriteFile(input, raw.baseAddress! + offset, DWORD(raw.count - offset), &written, nil), written > 0 else { return }
                offset += Int(written)
            }
        }
    }

    public func closeInput() {
        lock.withLock {
            if let input { CloseHandle(input) }
            input = nil
        }
    }

    /// Waits for the child to exit and returns its exit code.
    public func waitUntilExit() -> Int32 {
        WaitForSingleObject(process, INFINITE)
        var code: DWORD = 0
        GetExitCodeProcess(process, &code)
        lock.withLock { exited = true }
        return Int32(bitPattern: code)
    }

    public func terminate() {
        guard !lock.withLock({ exited }) else { return }
        TerminateProcess(process, 1)
    }

    public var processIdentifier: Int32 { Int32(GetProcessId(process)) }

    /// PROC_THREAD_ATTRIBUTE_HANDLE_LIST (a macro Swift can't import): ProcThreadAttributeValue(2, FALSE, TRUE, FALSE).
    static let handleListAttribute = DWORD_PTR(0x0002_0002)

    /// One argument quoted the way the C runtime (CommandLineToArgvW) splits a command line.
    static func quote(_ argument: String) -> String {
        guard argument.isEmpty || argument.contains(where: { " \t\n\"".contains($0) }) else { return argument }
        var result = "\""
        var backslashes = 0
        for character in argument {
            if character == "\\" {
                backslashes += 1
            } else if character == "\"" {
                result += String(repeating: "\\", count: backslashes * 2 + 1) + "\""
                backslashes = 0
            } else {
                result += String(repeating: "\\", count: backslashes) + String(character)
                backslashes = 0
            }
        }
        return result + String(repeating: "\\", count: backslashes * 2) + "\""
    }

    private static func lastError(_ what: String) -> NSError {
        NSError(domain: "ChildProcess", code: Int(GetLastError()), userInfo: [NSLocalizedDescriptionKey: "\(what) failed (Windows error \(GetLastError()))"])
    }
}
#endif
