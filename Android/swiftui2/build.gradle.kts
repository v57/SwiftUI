plugins {
    id("com.android.library")
}

android {
    namespace = "org.swiftui2"
    compileSdk = 36
    defaultConfig {
        minSdk = 28
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
