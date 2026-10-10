// `import Darwin` on other platforms: the platform's C library module (POSIX APIs), so code that
// only uses POSIX through Darwin compiles unchanged.
#if canImport(Android)
@_exported import Android
#elseif canImport(Glibc)
@_exported import Glibc
#elseif canImport(Musl)
@_exported import Musl
#elseif canImport(ucrt)
@_exported import ucrt
@_exported import WinSDK
#endif
@_exported import Foundation
