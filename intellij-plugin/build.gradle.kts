plugins {
    id("java")
    id("org.jetbrains.kotlin.jvm") version "2.0.21"
    id("org.jetbrains.intellij.platform") version "2.11.0"
}

group = "com.aidashboad"
version = "0.9.37"

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

dependencies {
    intellijPlatform {
        intellijIdeaCommunity("2023.3")
        // Dart plugin from marketplace (optional dependency)
        plugin("Dart", "233.11799.172")
        // Terminal plugin (bundled with IntelliJ)
        bundledPlugin("org.jetbrains.plugins.terminal")
    }
    // Gson for JSON parsing (MCP config management)
    implementation("com.google.code.gson:gson:2.10.1")
    // Note: Kotlin coroutines are provided by IntelliJ Platform, no need to add explicitly
}

intellijPlatform {
    pluginConfiguration {
        name = "Flutter Skill"
        ideaVersion {
            sinceBuild = "233"
            untilBuild = "253.*"
        }
    }

    pluginVerification {
        ides {
            recommended()
        }
        // Ignore failures from bundled plugins with version mismatches
        failureLevel = listOf(
            org.jetbrains.intellij.platform.gradle.tasks.VerifyPluginTask.FailureLevel.INVALID_PLUGIN
        )
    }

    signing {
        certificateChain = providers.environmentVariable("CERTIFICATE_CHAIN")
        privateKey = providers.environmentVariable("PRIVATE_KEY")
        password = providers.environmentVariable("PRIVATE_KEY_PASSWORD")
    }

    publishing {
        token = providers.environmentVariable("PUBLISH_TOKEN")
    }
}

tasks {
    withType<JavaCompile> {
        sourceCompatibility = "17"
        targetCompatibility = "17"
    }

    withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile> {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    // Skip test compilation by default (tests require IntelliJ IDE environment)
    // Run tests inside IntelliJ IDE instead of Gradle
    test {
        enabled = false
    }
    named("compileTestKotlin") {
        enabled = false
    }
}
