plugins {
    id("com.android.application")
}

// The Swift app library to run (lib<name>.so) and the package id: -PswiftLibrary=X -PappId=Y.
val swiftLibrary = (findProperty("swiftLibrary") as String?) ?: "DemoAndroid"
val appId = (findProperty("appId") as String?) ?: "org.swiftui.demo"
val appLabel = (findProperty("appLabel") as String?) ?: "SwiftUI Demo"

android {
    namespace = "org.swiftui.demo"
    compileSdk = 36
    defaultConfig {
        applicationId = appId
        manifestPlaceholders["swiftLibrary"] = swiftLibrary
        manifestPlaceholders["appLabel"] = appLabel
        minSdk = 28
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"
        ndk { abiFilters += "arm64-v8a" }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildTypes {
        // Not debuggable (ART compiles the host code fully), signed with the debug key so it
        // installs like the debug build.
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    packaging {
        // The Swift runtime libraries are prebuilt; keep them as they are.
        jniLibs { useLegacyPackaging = true; keepDebugSymbols += "**/*.so" }
    }
}

dependencies {
    implementation(project(":swiftui"))
}
