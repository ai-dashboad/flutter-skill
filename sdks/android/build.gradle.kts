plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

group = "com.flutterskill"
version = "0.9.37"

android {
    namespace = "com.flutterskill"
    compileSdk = 34

    defaultConfig {
        minSdk = 24

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }
}

dependencies {
    // Android core — typically already present in host apps
    implementation("androidx.core:core-ktx:1.12.0")

    // Kotlin coroutines — for async server operations
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
}
