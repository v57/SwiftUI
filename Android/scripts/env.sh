# Environment for cross-compiling SwiftUI2 to Android. Source it: `. Android/scripts/env.sh`.
# The Swift Android SDK is 6.3.3, so the host compiler must be the matching open-source
# toolchain; it can't parse Xcode 27's macOS SDK (used for manifests and macros), hence the
# Command Line Tools' 26.5 SDK.
export SWIFT_ANDROID_TOOLCHAIN="${SWIFT_ANDROID_TOOLCHAIN:-$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain}"
export SWIFT_ANDROID_SDK_BUNDLE="${SWIFT_ANDROID_SDK_BUNDLE:-$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.3-RELEASE_android.artifactbundle}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$SWIFT_ANDROID_SDK_BUNDLE/swift-android/android-ndk-r27d}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
export SDKROOT="${SWIFT_ANDROID_HOST_SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
export SWIFT_ANDROID_TRIPLE="${SWIFT_ANDROID_TRIPLE:-aarch64-unknown-linux-android28}"
export ADB="$ANDROID_HOME/platform-tools/adb"
# Swift runtime libraries to ship next to the app's .so.
export SWIFT_ANDROID_RUNTIME_LIBS="$SWIFT_ANDROID_SDK_BUNDLE/swift-android/swift-resources/usr/lib/swift-aarch64/android"
