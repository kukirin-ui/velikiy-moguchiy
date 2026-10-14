# Third-party code, data and libraries

The Android keyboard (`android/`) is written for this repository. It ports the iPhone keyboard's
layout, typing and suggestion rules from `ios/Shared/Keyboard` and the DashScope realtime protocol
from `ios/App/DashScope` and `mac/velikiy-moguchiy-asr/src/qwen.rs`.

## Code and data in this folder

| Source | License | What was taken |
| --- | --- | --- |
| KeyboardKit 9.9.1, through `ios/Shared/Keyboard` | MIT, Copyright (c) 2016-2025 Daniel Saidi (notice below) | Concepts of the layout and shift/page state in `keyboard/KeyboardLayout.kt`. |
| [AOSP LatinIME dictionaries](https://android.googlesource.com/platform/packages/inputmethods/LatinIME/+/127336e9f29d69607eab55982324b210279ae8c5/dictionaries/) (`ru_wordlist.combined.gz`, `en_US_wordlist.combined.gz`) | Apache-2.0, Copyright (c) 2008, The Android Open Source Project | `app/src/main/assets/dictionary/*.tsv`: words and frequencies, cut by frequency and stripped of personal names by `tools/build_wordlists.py`; the typo whitelist (`*.replacements.tsv`). |
| [Material Icons](https://github.com/google/material-design-icons) "mic" | Apache-2.0, Copyright Google LLC | The microphone path of the launcher icon (`res/drawable/ic_launcher_foreground.xml`). |

The keyboard's own key glyphs are drawn in code (`ime/KeyDrawing.kt`).

## Libraries in the APK

All under Apache-2.0: AndroidX Core, Activity, Lifecycle and SavedState; Jetpack Compose (UI, Foundation,
Material 3); Kotlin standard library; kotlinx.coroutines; kotlinx.serialization (JSON); OkHttp and Okio.
Versions are in `gradle/libs.versions.toml`.

## KeyboardKit notice

KeyboardKit 9.9.1 is Copyright (c) 2016-2025 Daniel Saidi and is provided under
the MIT License:

> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

Source: https://github.com/KeyboardKit/KeyboardKit/tree/9.9.1
