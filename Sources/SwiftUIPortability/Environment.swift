#if os(Windows)
import Foundation
import WinSDK

/// POSIX `setenv`, which Windows' C runtime lacks: sets `name` in the process environment (Win32's, which
/// `ProcessInfo` and child processes read, and the C runtime's, which `getenv` reads). Returns 0, or -1 when it
/// couldn't. With `overwrite` 0 an existing value stays.
@discardableResult
public func setenv(_ name: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>, _ overwrite: Int32) -> Int32 {
    let key = String(cString: name)
    let text = String(cString: value)
    if overwrite == 0, ProcessInfo.processInfo.environment[key] != nil { return 0 }
    let set = key.withCString(encodedAs: UTF16.self) { key in
        text.withCString(encodedAs: UTF16.self) { SetEnvironmentVariableW(key, $0) }
    }
    guard set, _putenv_s(name, value) == 0 else { return -1 }
    return 0
}

/// POSIX `unsetenv`: removes `name` from the process environment.
@discardableResult
public func unsetenv(_ name: UnsafePointer<CChar>) -> Int32 {
    let removed = String(cString: name).withCString(encodedAs: UTF16.self) { SetEnvironmentVariableW($0, nil) }
    guard removed, _putenv_s(name, "") == 0 else { return -1 }
    return 0
}
#endif
