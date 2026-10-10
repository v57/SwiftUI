plugins {
    id("com.android.application")
}

android {
    namespace = "org.swiftui2.demo"
    compileSdk = 36
    defaultConfig {
        applicationId = "org.swiftui2.demo"
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
    packaging {
        // The Swift runtime libraries are prebuilt; keep them as they are.
        jniLibs { useLegacyPackaging = true; keepDebugSymbols += "**/*.so" }
    }
}

dependencies {
    implementation(project(":swiftui2"))
}
