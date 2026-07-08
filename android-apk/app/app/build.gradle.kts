import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Release signing is driven by env vars (see build.sh / secrets.local.env):
//   YACF_KEYSTORE, YACF_KEYSTORE_PASS, YACF_KEY_ALIAS, YACF_KEY_PASS
// If YACF_KEYSTORE is unset, assembleRelease falls back to the debug keystore
// (fine for personal sideload).
val keystorePath: String? = System.getenv("YACF_KEYSTORE")

android {
    namespace = "io.yacf"
    compileSdk = 35

    defaultConfig {
        applicationId = "io.yacf"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    signingConfigs {
        if (keystorePath != null) {
            create("release") {
                storeFile = file(keystorePath)
                storePassword = System.getenv("YACF_KEYSTORE_PASS")
                keyAlias = System.getenv("YACF_KEY_ALIAS")
                keyPassword = System.getenv("YACF_KEY_PASS")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = if (keystorePath != null) {
                signingConfigs.getByName("release")
            } else {
                // Personal sideload: sign with the debug key so the APK installs.
                signingConfigs.getByName("debug")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation(files("libs/yacf.aar"))
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
}
