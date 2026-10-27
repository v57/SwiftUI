// A child process that inherits only its own standard handles (Windows and Linux). Foundation's `Process` there lets
// every child inherit every inheritable handle of the app (other children's pipes, files the C runtime opened):
// running processes side by side, one child keeps another's pipe open (no end of output until it exits) or a file
// the app is replacing (a sharing violation). On Linux swift-corelibs-foundation also learns of an exit only once
// every holder of the child's descriptors is gone, so `Process`es started side by side wait on one another.
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
    /// child's standard input is a pipe (`write`, `closeInput`), else NUL. Arguments are quoted the way the C
    /// runtime splits them; `verbatimArguments` joins them as they are (`cmd /s /c "…"` reads its own).
    public init(
        executable: URL, arguments: [String], directory: URL?, environment: [String: String], input: Bool = false,
        verbatimArguments: Bool = false
    ) throws {
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

        // Native paths: cmd reads the "/" of "C:/Windows/System32/cmd.exe" in its own command line as switches.
        let program = Self.nativePath(executable.path)
        let line = ([Self.quote(program)] + (verbatimArguments ? arguments : arguments.map(Self.quote)))
            .joined(separator: " ")
        var commandLine = Array(line.utf16) + [0]
        let block = environment.sorted { $0.key.uppercased() < $1.key.uppercased() }.map { "\($0.key)=\($0.value)" }
        var environmentBlock = Array((block.joined(separator: "\0") + "\0\0").utf16)
        var info = PROCESS_INFORMATION()
        let flags = DWORD(CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW)
        let created = program.withCString(encodedAs: UTF16.self) { application in
            Self.nativePath(directory?.path ?? FileManager.default.currentDirectoryPath).withCString(encodedAs: UTF16.self) { cwd in
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
            throw Self.lastError("CreateProcess \(program)")
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

    /// A path with Windows' separators ("C:/dev" → "C:\\dev"); URL paths use "/".
    static func nativePath(_ path: String) -> String {
        var path = path
        // "/C:/dev" (a URL path) → "C:/dev".
        if path.hasPrefix("/"), path.dropFirst().dropFirst().hasPrefix(":") { path.removeFirst() }
        return path.replacingOccurrences(of: "/", with: "\\")
    }

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
#elseif os(Linux)
import Foundation
import Glibc

public final class ChildProcess: @unchecked Sendable {
    public enum Stream: Sendable { case output, error }

    private let pid: pid_t
    private let output: Int32
    private let error: Int32
    private var input: Int32?
    private let lock = NSLock()
    private var exited = false
    private var exitCode: Int32 = 0

    /// Starts `executable` with `arguments` in `directory` (posix_spawn, in a process group of its own, every
    /// descriptor but the three standard ones closed). `environment` replaces the app's; with `input` the child's
    /// standard input is a pipe (`write`, `closeInput`), else /dev/null. `verbatimArguments` is for Windows' command
    /// lines and changes nothing here.
    public init(
        executable: URL, arguments: [String], directory: URL?, environment: [String: String], input: Bool = false,
        verbatimArguments: Bool = false
    ) throws {
        _ = Self.ignoresBrokenPipes
        func makePipe() throws -> (read: Int32, write: Int32) {
            var ends: [Int32] = [-1, -1]
            guard pipe(&ends) == 0 else { throw Self.lastError("pipe") }
            // The app's ends never reach another child (the spawn below closes the rest itself).
            for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
            return (ends[0], ends[1])
        }
        let out = try makePipe(), err = try makePipe()
        var childInput: Int32
        if input {
            let pipe = try makePipe()
            childInput = pipe.read
            self.input = pipe.write
        } else {
            childInput = open("/dev/null", O_RDONLY | O_CLOEXEC)
        }
        defer {
            close(childInput)
            close(out.write)
            close(err.write)
        }

        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, childInput, 0)
        posix_spawn_file_actions_adddup2(&actions, out.write, 1)
        posix_spawn_file_actions_adddup2(&actions, err.write, 2)
        posix_spawn_file_actions_addclosefrom_np(&actions, 3)
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory.path) }

        var attributes = posix_spawnattr_t()
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group, so `terminate` reaches what it starts too; default signal handling (the app may
        // ignore SIGPIPE, which a child would inherit) and no blocked signals.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGINT, SIGTERM, SIGQUIT, SIGCHLD] { sigaddset(&defaults, signal) }
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let argv = ([executable.path] + arguments).map { strdup($0) }
        let envp = environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            for pointer in argv + envp { free(pointer) }
        }
        var pid: pid_t = 0
        let status = (argv + [nil]).withUnsafeBufferPointer { argvBuffer in
            (envp + [nil]).withUnsafeBufferPointer { envpBuffer in
                posix_spawn(&pid, executable.path, &actions, &attributes, argvBuffer.baseAddress!, envpBuffer.baseAddress!)
            }
        }
        guard status == 0 else {
            close(out.read)
            close(err.read)
            if let input = self.input { close(input) }
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Couldn't run \(executable.path): \(String(cString: strerror(status)))"])
        }
        self.pid = pid
        output = out.read
        error = err.read
    }

    deinit {
        close(output)
        close(error)
        if let input { close(input) }
    }

    /// Reads a stream until the child closes it, handing on each chunk (blocking: call it on its own thread).
    public func read(_ stream: Stream, chunk: (Data) -> Void) {
        let descriptor = stream == .output ? output : error
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Glibc.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            chunk(Data(buffer[0..<count]))
        }
    }

    /// Writes to the child's standard input (a pipe when made with `input`).
    public func write(_ data: Data) {
        guard let input = lock.withLock({ self.input }) else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Glibc.write(input, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    public func closeInput() {
        lock.withLock {
            if let input { close(input) }
            input = nil
        }
    }

    /// Waits for the child to exit and returns its exit code (128 + the signal's number when a signal ended it).
    public func waitUntilExit() -> Int32 {
        if let code = lock.withLock({ exited ? exitCode : nil }) { return code }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let signal = status & 0x7F
        let code = signal == 0 ? (status >> 8) & 0xFF : 128 + signal
        lock.withLock {
            exited = true
            exitCode = code
        }
        return code
    }

    /// Ends the child and the processes it started (its process group).
    public func terminate() {
        guard !lock.withLock({ exited }) else { return }
        kill(-pid, SIGTERM)
    }

    public var processIdentifier: Int32 { pid }

    /// A child that exits before reading all its input must fail the write (EPIPE), not end the app with SIGPIPE:
    /// the app ignores the signal from its first child on (children get the default back).
    private static let ignoresBrokenPipes: Bool = {
        signal(SIGPIPE, SIG_IGN)
        return true
    }()

    private static func lastError(_ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(what) failed: \(String(cString: strerror(errno)))"])
    }
}
#endif
