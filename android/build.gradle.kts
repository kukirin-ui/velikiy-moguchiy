plugins {
    alias(libs.plugins.android.application) apply false
    // AGP's built-in Kotlin uses the newest Kotlin Gradle plugin on the build classpath.
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
}
