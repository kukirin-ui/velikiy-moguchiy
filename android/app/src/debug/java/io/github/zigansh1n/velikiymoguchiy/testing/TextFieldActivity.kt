package io.github.zigansh1n.velikiymoguchiy.testing

import android.app.Activity
import android.os.Bundle
import android.text.InputType
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.EditText
import android.widget.FrameLayout

/** Debug builds only: one ordinary text field for the emulator tests to type and dictate into. */
class TextFieldActivity : Activity() {
    lateinit var field: EditText
        private set

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        field = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            hint = "Поле для проверки клавиатуры"
        }
        val padding = (24 * resources.displayMetrics.density).toInt()
        setContentView(
            FrameLayout(this).apply {
                fitsSystemWindows = true
                setPadding(padding, padding, padding, padding)
                addView(field, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            },
        )
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE)
        field.requestFocus()
    }
}
