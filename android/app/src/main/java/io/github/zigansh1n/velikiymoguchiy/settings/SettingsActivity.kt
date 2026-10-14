package io.github.zigansh1n.velikiymoguchiy.settings

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import io.github.zigansh1n.velikiymoguchiy.BuildConfig
import io.github.zigansh1n.velikiymoguchiy.dictation.DashScopeModel
import io.github.zigansh1n.velikiymoguchiy.dictation.DashScopeProtocol
import io.github.zigansh1n.velikiymoguchiy.dictation.DashScopeRegion
import io.github.zigansh1n.velikiymoguchiy.dictation.DashScopeSession
import io.github.zigansh1n.velikiymoguchiy.dictation.DictationException
import io.github.zigansh1n.velikiymoguchiy.dictation.DictationLanguage
import io.github.zigansh1n.velikiymoguchiy.dictation.OkHttpSocketFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The keyboard's settings app: setup steps, the DashScope key and typing switches. */
class SettingsActivity : ComponentActivity() {
    private lateinit var settings: AppSettings
    private var status by mutableStateOf(SetupStatus(enabled = false, selected = false, microphone = false))

    private val microphoneRequest = registerForActivityResult(ActivityResultContracts.RequestPermission()) { refreshStatus() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        settings = AppSettings(this)
        refreshStatus()
        if (savedInstanceState == null && intent.getBooleanExtra(EXTRA_REQUEST_MICROPHONE, false) && !status.microphone) {
            microphoneRequest.launch(Manifest.permission.RECORD_AUDIO)
        }
        setContent {
            MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()) {
                Surface(Modifier.fillMaxSize()) {
                    SettingsScreen(
                        settings = settings,
                        status = status,
                        onOpenKeyboards = { startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)) },
                        onPickKeyboard = { (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).showInputMethodPicker() },
                        onRequestMicrophone = { requestMicrophone() },
                        onOpenLink = { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(it))) },
                    )
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        refreshStatus()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // The keyboard picker is a dialog over this window: re-check once it closes.
        if (hasFocus) refreshStatus()
    }

    private fun requestMicrophone() {
        // After "don't ask again" the request returns at once: only the app's system page can grant it.
        if (status.microphoneAsked && !shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)) {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
        } else {
            microphoneRequest.launch(Manifest.permission.RECORD_AUDIO)
        }
        status = status.copy(microphoneAsked = true)
    }

    private fun refreshStatus() {
        val imm = getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
        val enabled = imm.enabledInputMethodList.any { it.packageName == packageName }
        val current = Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD).orEmpty()
        status = status.copy(
            enabled = enabled,
            selected = current.startsWith("$packageName/"),
            microphone = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED,
        )
    }

    companion object {
        const val EXTRA_REQUEST_MICROPHONE = "request_microphone"
    }
}

data class SetupStatus(val enabled: Boolean, val selected: Boolean, val microphone: Boolean, val microphoneAsked: Boolean = false)

private const val LICENSES_ASSET = "licenses.txt"
private const val REPOSITORY_URL = "https://github.com/zigansh1n/velikiy-moguchiy"
private const val DASHSCOPE_URL = "https://bailian.console.aliyun.com/"
private const val DASHSCOPE_INTL_URL = "https://modelstudio.console.alibabacloud.com/"

@Composable
private fun SettingsScreen(
    settings: AppSettings,
    status: SetupStatus,
    onOpenKeyboards: () -> Unit,
    onPickKeyboard: () -> Unit,
    onRequestMicrophone: () -> Unit,
    onOpenLink: (String) -> Unit,
) {
    Column(
        Modifier
            .fillMaxSize()
            .safeDrawingPadding()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("«Великий & Могучий»", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
        Text("Клавиатура с русской и английской раскладкой и голосовым вводом.", style = MaterialTheme.typography.bodyMedium)

        Section("Как включить") {
            Step(
                done = status.enabled,
                title = "1. Включите клавиатуру",
                text = "В списке клавиатур Android включите «Великий & Могучий». Android предупредит, что клавиатура видит " +
                    "набираемый текст: так он говорит о любой сторонней клавиатуре.",
                action = "Открыть список клавиатур",
                onAction = onOpenKeyboards,
            )
            Step(
                done = status.selected,
                title = "2. Сделайте её текущей",
                text = "Выберите «Великий & Могучий» в переключателе клавиатур.",
                action = "Выбрать клавиатуру",
                onAction = onPickKeyboard,
            )
            Step(
                done = status.microphone,
                title = "3. Разрешите микрофон",
                text = "Нужен только для кнопки диктовки. Звук записывается, пока вы диктуете.",
                action = "Разрешить микрофон",
                onAction = onRequestMicrophone,
            )
        }

        DictationSection(settings, onOpenLink)
        TypingSection(settings)

        Section("Попробовать") {
            var sample by remember { mutableStateOf("") }
            OutlinedTextField(
                value = sample,
                onValueChange = { sample = it },
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text("Напечатайте или надиктуйте что-нибудь") },
                minLines = 3,
            )
        }

        Section("О программе") {
            Text("Версия ${BuildConfig.VERSION_NAME}. Открытый исходный код.", style = MaterialTheme.typography.bodyMedium)
            Text(
                "Клавиатура ничего не собирает и не отправляет. Звук диктовки уходит только в DashScope по вашему " +
                    "ключу или, если вы это включили, в распознавание речи Android. Набранный текст остаётся на телефоне.",
                style = MaterialTheme.typography.bodySmall,
            )
            TextButton(onClick = { onOpenLink(REPOSITORY_URL) }) { Text("Исходный код на GitHub") }
            var showLicenses by remember { mutableStateOf(false) }
            TextButton(onClick = { showLicenses = true }) { Text("Лицензии") }
            if (showLicenses) LicensesDialog(onClose = { showLicenses = false })
        }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun DictationSection(settings: AppSettings, onOpenLink: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var keyInput by remember { mutableStateOf("") }
    var hasKey by remember { mutableStateOf(settings.hasApiKey) }
    var model by remember { mutableStateOf(settings.model) }
    var region by remember { mutableStateOf(settings.region) }
    var message by remember { mutableStateOf<String?>(null) }
    var checking by remember { mutableStateOf(false) }

    Section("Диктовка") {
        Text(
            if (hasKey) {
                "Ключ DashScope сохранён: диктовка идёт через Qwen."
            } else {
                "Для диктовки нужен ключ DashScope. Без него микрофон работает, только если ниже включено " +
                    "распознавание речи Android."
            },
            style = MaterialTheme.typography.bodyMedium,
        )
        OutlinedTextField(
            value = keyInput,
            onValueChange = { keyInput = it.trim() },
            modifier = Modifier.fillMaxWidth(),
            label = { Text(if (hasKey) "Новый ключ DashScope" else "Ключ DashScope") },
            placeholder = { Text("sk-…") },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(
                enabled = DashScopeProtocol.isUsableKey(keyInput),
                onClick = {
                    settings.setApiKey(keyInput)
                    keyInput = ""
                    hasKey = settings.hasApiKey
                    message = "Ключ сохранён на телефоне в зашифрованном виде."
                },
            ) { Text("Сохранить") }
            OutlinedButton(
                enabled = hasKey && !checking,
                onClick = {
                    checking = true
                    message = "Проверяю…"
                    scope.launch {
                        message = checkKey(settings)
                        checking = false
                    }
                },
            ) { Text("Проверить") }
            if (hasKey) {
                TextButton(onClick = {
                    settings.setApiKey(null)
                    hasKey = false
                    message = "Ключ удалён."
                }) { Text("Удалить") }
            }
        }
        message?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        Text(
            "Ключ выдаёт Alibaba Cloud Model Studio (DashScope). Ключ китайского региона работает только с китайским " +
                "адресом, международный — только с международным.",
            style = MaterialTheme.typography.bodySmall,
        )
        Row {
            TextButton(onClick = { onOpenLink(DASHSCOPE_URL) }) { Text("Консоль (Китай)") }
            TextButton(onClick = { onOpenLink(DASHSCOPE_INTL_URL) }) { Text("Консоль (международная)") }
        }

        Text("Регион ключа", fontWeight = FontWeight.SemiBold)
        Choice("Международный (dashscope-intl.aliyuncs.com)", region == DashScopeRegion.INTERNATIONAL) {
            region = DashScopeRegion.INTERNATIONAL
            settings.region = region
        }
        Choice("Китай (dashscope.aliyuncs.com)", region == DashScopeRegion.CHINA) {
            region = DashScopeRegion.CHINA
            settings.region = region
        }

        Text("Модель", fontWeight = FontWeight.SemiBold)
        Choice("Qwen3 ASR — дословно и быстро (${DashScopeModel.ASR.id})", model == DashScopeModel.ASR) {
            model = DashScopeModel.ASR
            settings.model = model
        }
        Choice("Qwen Omni — переписывает речь в аккуратный текст (${DashScopeModel.OMNI.id})", model == DashScopeModel.OMNI) {
            model = DashScopeModel.OMNI
            settings.model = model
        }

        Toggle(
            "Распознавание речи Android без ключа",
            "Выключено по умолчанию. Если ключа DashScope нет, звук уходит в службу распознавания речи, " +
                "установленную на телефоне. Обычно это Google, и звук может отправляться на её серверы — " +
                "по её правилам, не по нашим. С ключом эта настройка не используется.",
            settings.systemSpeech,
        ) { settings.systemSpeech = it }
    }
}

/** Opens a session with the saved key and closes it once DashScope has accepted the settings. */
private suspend fun checkKey(settings: AppSettings): String = withContext(Dispatchers.IO) {
    val key = settings.apiKey() ?: return@withContext "Ключа нет."
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    try {
        val endpoint = DashScopeProtocol.endpoint(key, settings.model, settings.region)
        val session = DashScopeSession(endpoint, settings.model, DictationLanguage.RUSSIAN, OkHttpSocketFactory(), scope)
        session.connect()
        session.cancel()
        "Ключ работает: DashScope принял сеанс ${settings.model.id}."
    } catch (error: DictationException) {
        error.message.orEmpty()
    } finally {
        scope.cancel()
    }
}

@Composable
private fun TypingSection(settings: AppSettings) {
    Section("Набор") {
        Toggle("Автоисправление", "Исправляет опечатку на пробеле; ⌫ сразу после этого возвращает слово.", settings.autocorrect) {
            settings.autocorrect = it
        }
        Toggle("Заглавные автоматически", "В начале предложения и после точки.", settings.autocapitalization) {
            settings.autocapitalization = it
        }
        Toggle("Кавычки «ёлочки» и тире", "\" превращается в « », -- в —, ... в …", settings.smartPunctuation) {
            settings.smartPunctuation = it
        }
        Toggle("Точка двойным пробелом", null, settings.doubleSpacePeriod) { settings.doubleSpacePeriod = it }
        Toggle("Вибрация клавиш", null, settings.keyVibration) { settings.keyVibration = it }
        Toggle("Звук клавиш", null, settings.keySound) { settings.keySound = it }
        var kept by remember { mutableStateOf(settings.keptWords.size) }
        if (kept > 0) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Слов, оставленных как есть: $kept", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                TextButton(onClick = {
                    settings.keptWords = emptySet()
                    kept = 0
                }) { Text("Забыть") }
            }
        }
        Text(
            "Клавиша 🌐 переключает русский и английский, долгое нажатие на ней открывает список клавиатур, " +
                "на микрофоне — эти настройки.",
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

/** Third-party notices shipped in the APK (assets/licenses.txt). */
@Composable
private fun LicensesDialog(onClose: () -> Unit) {
    val context = LocalContext.current
    val text = remember {
        runCatching { context.assets.open(LICENSES_ASSET).bufferedReader().use { it.readText() } }
            .getOrDefault("Файл лицензий не найден.")
    }
    AlertDialog(
        onDismissRequest = onClose,
        confirmButton = { TextButton(onClick = onClose) { Text("Закрыть") } },
        title = { Text("Лицензии") },
        text = {
            Text(
                text,
                Modifier.verticalScroll(rememberScrollState()),
                style = MaterialTheme.typography.bodySmall,
            )
        },
    )
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            content()
        }
    }
}

@Composable
private fun Step(done: Boolean, title: String, text: String, action: String, onAction: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(if (done) "$title — готово ✓" else title, fontWeight = FontWeight.Medium)
        Text(text, style = MaterialTheme.typography.bodySmall)
        if (!done) OutlinedButton(onClick = onAction) { Text(action) }
    }
}

@Composable
private fun Choice(title: String, selected: Boolean, onSelect: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .selectable(selected = selected, onClick = onSelect),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = onSelect)
        Text(title, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun Toggle(title: String, subtitle: String?, initial: Boolean, onChange: (Boolean) -> Unit) {
    var checked by remember { mutableStateOf(initial) }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        }
        Switch(checked = checked, onCheckedChange = {
            checked = it
            onChange(it)
        })
    }
}
