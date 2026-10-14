package io.github.zigansh1n.velikiymoguchiy.settings

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.github.zigansh1n.velikiymoguchiy.dictation.DashScopeModel
import io.github.zigansh1n.velikiymoguchiy.dictation.DashScopeProtocol
import io.github.zigansh1n.velikiymoguchiy.dictation.DashScopeRegion
import io.github.zigansh1n.velikiymoguchiy.keyboard.LayoutLanguage
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Keyboard preferences shared by the settings screen and the input method (one process). */
class AppSettings(context: Context) {
    private val prefs: SharedPreferences = context.applicationContext.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private val secrets = SecretStore(prefs)

    var model: DashScopeModel
        get() = DashScopeModel.entries.firstOrNull { it.name == prefs.getString(MODEL, null) } ?: DashScopeModel.ASR
        set(value) = prefs.edit().putString(MODEL, value.name).apply()

    var region: DashScopeRegion
        get() = DashScopeRegion.entries.firstOrNull { it.name == prefs.getString(REGION, null) } ?: DashScopeRegion.INTERNATIONAL
        set(value) = prefs.edit().putString(REGION, value.name).apply()

    var autocorrect by flag("autocorrect", true)
    var autocapitalization by flag("autocapitalization", true)
    var smartPunctuation by flag("smart_punctuation", true)
    var doubleSpacePeriod by flag("double_space_period", true)
    var keySound by flag("key_sound", false)

    /** Without a DashScope key, dictate through Android's speech service; it may send audio to Google. */
    var systemSpeech by flag("system_speech", false)
    var keyVibration by flag("key_vibration", true)

    var language: LayoutLanguage
        get() = LayoutLanguage.fromCode(prefs.getString(LANGUAGE, null))
        set(value) = prefs.edit().putString(LANGUAGE, value.code).apply()

    /** Words the user kept as typed: never corrected again. */
    var keptWords: Set<String>
        get() = prefs.getStringSet(KEPT_WORDS, emptySet()).orEmpty()
        set(value) = prefs.edit().putStringSet(KEPT_WORDS, value.toSet()).apply()

    fun keepWord(word: String) {
        if (word.isNotBlank()) keptWords = keptWords + word.lowercase()
    }

    val hasApiKey: Boolean get() = DashScopeProtocol.isUsableKey(apiKey())

    fun apiKey(): String? = secrets.read(API_KEY)

    fun setApiKey(value: String?) {
        val key = value?.trim().orEmpty()
        if (key.isEmpty()) secrets.remove(API_KEY) else secrets.write(API_KEY, key)
    }

    fun registerListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) =
        prefs.registerOnSharedPreferenceChangeListener(listener)

    fun unregisterListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) =
        prefs.unregisterOnSharedPreferenceChangeListener(listener)

    private fun flag(name: String, default: Boolean) = object : kotlin.properties.ReadWriteProperty<Any?, Boolean> {
        override fun getValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>) = prefs.getBoolean(name, default)
        override fun setValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>, value: Boolean) =
            prefs.edit().putBoolean(name, value).apply()
    }

    private companion object {
        const val MODEL = "dashscope_model"
        const val REGION = "dashscope_region"
        const val LANGUAGE = "language"
        const val KEPT_WORDS = "kept_words"
        const val API_KEY = "dashscope_api_key"
    }
}

/**
 * Values encrypted with an AES-GCM key that never leaves the Android Keystore. The app also opts
 * out of backups, so the DashScope key stays on this phone.
 */
private class SecretStore(private val prefs: SharedPreferences) {
    fun read(name: String): String? {
        val stored = prefs.getString(name, null) ?: return null
        return try {
            val bytes = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, IV_BYTES))
            String(cipher.doFinal(bytes, IV_BYTES, bytes.size - IV_BYTES), Charsets.UTF_8)
        } catch (_: Exception) {
            // A restored or reset Keystore cannot decrypt the old value: ask for the key again.
            null
        }
    }

    fun write(name: String, value: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        prefs.edit().putString(name, Base64.encodeToString(encrypted, Base64.NO_WRAP)).apply()
    }

    fun remove(name: String) = prefs.edit().remove(name).apply()

    private fun key(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "dashscope-key"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
    }
}
