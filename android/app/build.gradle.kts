plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// A tag build passes -PvmVersionName=0.2.0 -PvmVersionCode=200; local builds stay "dev".
val versionNameProperty = providers.gradleProperty("vmVersionName").orElse("0.0.0-dev")
val versionCodeProperty = providers.gradleProperty("vmVersionCode").map(String::toInt).orElse(1)

// Release signing is optional: without these variables the release APK is unsigned.
val signingStore = providers.environmentVariable("VM_KEYSTORE_FILE")
val signingStorePassword = providers.environmentVariable("VM_KEYSTORE_PASSWORD")
val signingKeyAlias = providers.environmentVariable("VM_KEY_ALIAS")
val signingKeyPassword = providers.environmentVariable("VM_KEY_PASSWORD")

android {
    namespace = "io.github.zigansh1n.velikiymoguchiy"
    compileSdk = 37

    defaultConfig {
        applicationId = "io.github.zigansh1n.velikiymoguchiy"
        minSdk = 23
        targetSdk = 36
        versionCode = versionCodeProperty.get()
        versionName = versionNameProperty.get()
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (signingStore.isPresent) {
            create("release") {
                storeFile = file(signingStore.get())
                storePassword = signingStorePassword.get()
                keyAlias = signingKeyAlias.get()
                keyPassword = signingKeyPassword.get()
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release")
        }
    }

    androidResources {
        // The libraries' own translations are not shown anywhere in this app.
        localeFilters += listOf("ru", "en")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)

    androidTestImplementation(libs.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.rules)
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.androidx.test.uiautomator)
}
