plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Release signing: values come from ~/.gradle/gradle.properties or environment variables
// (PHONEBOX_STORE_FILE, PHONEBOX_STORE_PASSWORD, PHONEBOX_KEY_ALIAS, PHONEBOX_KEY_PASSWORD, optional PHONEBOX_STORE_TYPE).
// Without them, release builds fall back to the debug key so the project still builds anywhere.
fun signingValue(name: String): String? =
    (project.findProperty(name) as String?) ?: System.getenv(name)

android {
    // The Kotlin package stays net.oxog.phonebox.deskpanel (upstream PhoneBox); the installed app is NikoDeck, so it
    // can sit next to an original PhoneBox install. The agent (UsbLink.Package, AdbReverse) uses the applicationId.
    namespace = "net.oxog.phonebox.deskpanel"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.lordsigfrid.nikodeck"
        minSdk = 21 // Android 5.0; see CONTRIBUTING.md before changing it
        targetSdk = 35
        versionCode = 53
        versionName = "1.0.2"
    }

    signingConfigs {
        val storeFile = signingValue("PHONEBOX_STORE_FILE")
        if (storeFile != null && file(storeFile).exists()) {
            create("release") {
                this.storeFile = file(storeFile)
                storePassword = signingValue("PHONEBOX_STORE_PASSWORD")
                keyAlias = signingValue("PHONEBOX_KEY_ALIAS")
                keyPassword = signingValue("PHONEBOX_KEY_PASSWORD")
                // Unset, the JDK's default type is used: PKCS12 on Java 9+, which also reads a JKS file
                // (keystore.type.compat), so an openssl-made .p12 and an old .jks both work. PHONEBOX_STORE_TYPE
                // (pkcs12 or jks) forces one.
                signingValue("PHONEBOX_STORE_TYPE")?.takeIf { it.isNotBlank() }?.let { storeType = it }
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    buildFeatures {
        buildConfig = true
    }

    lint {
        // Unsupported framework calls can crash old phones before the panel opens.
        fatal += "NewApi"
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
    implementation("androidx.webkit:webkit:1.12.1")
    testImplementation("junit:junit:4.13.2")
    // android.jar's org.json is a stub on the JVM; the real one lets the unit tests build and read JSON
    testImplementation("org.json:json:20240303")
}
