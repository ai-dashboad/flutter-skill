plugins {
    kotlin("multiplatform") version "1.9.22"
    id("com.android.library") version "8.2.0"
}

group = "com.flutterskill"
version = "0.9.37"

kotlin {
    androidTarget {
        compilations.all {
            kotlinOptions { jvmTarget = "17" }
        }
    }
    jvm("jvm")
    iosX64()
    iosArm64()
    iosSimulatorArm64()

    sourceSets {
        val commonMain by getting {
            dependencies {
                implementation("io.ktor:ktor-server-core:2.3.7")
                implementation("io.ktor:ktor-server-websockets:2.3.7")
                implementation("io.ktor:ktor-server-cio:2.3.7")
                implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.2")
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3")
            }
        }
        val androidMain by getting
        val jvmMain by getting
    }
}

android {
    namespace = "com.flutterskill"
    compileSdk = 34
    defaultConfig { minSdk = 24 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
