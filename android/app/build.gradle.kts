import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

/**
 * Signing.
 *
 * In-app updates only work when every build of NexRadar carries the *same*
 * signature: Android refuses to replace an installed package with an APK signed
 * by a different key (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`). CI is a fresh
 * machine with no `~/.android/debug.keystore`, so it would silently mint a new
 * debug key on every run and break the update chain after the very first build.
 *
 * `android/key.properties` (git-ignored, injected from repository secrets in CI)
 * therefore pins the release signature:
 *
 *     storeFile=/absolute/path/nexradar.jks
 *     storePassword=…
 *     keyAlias=…
 *     keyPassword=…
 *
 * Without the file the build falls back to the debug key, which is what a plain
 * `flutter run --release` on a developer machine expects.
 */
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}
val releaseKeystore = keystorePropertiesFile.exists()

android {
    namespace = "com.nexradar.app"
    // permission_handler_android (>=13) ships AAR metadata that demands API 37,
    // so we compile one level above Flutter's default. compileSdk is purely a
    // build-time ceiling: minSdk/targetSdk stay where Flutter put them.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.nexradar.app"
        // 26 (Android 8) is the floor: foreground services, notification
        // channels and TYPE_APPLICATION_OVERLAY all behave predictably from
        // here, and every device that can run a floating HUD has it.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (releaseKeystore) {
        signingConfigs {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (releaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
