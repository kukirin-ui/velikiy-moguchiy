import UIKit

extension KeyboardViewController: KeyboardSurfaceViewDelegate {
  func keyboardSurface(_ surface: KeyboardSurfaceView, insertText text: String) {
    typeText(text)
  }

  func keyboardSurfaceDeleteBackward(_ surface: KeyboardSurfaceView) {
    store.noteKeyboardActive()
    lastSpaceInsertedAt = nil
    if revertLastReplacementIfPossible() { return }
    textDocumentProxy.deleteBackward()
    refreshTextStateSoon()
  }

  func keyboardSurfaceDeleteWordBackward(_ surface: KeyboardSurfaceView) {
    store.noteKeyboardActive()
    lastSpaceInsertedAt = nil
    lastReplacement = nil
    let count = DeleteWordRange.characterCount(
      contextBefore: textDocumentProxy.documentContextBeforeInput)
    for _ in 0..<count { textDocumentProxy.deleteBackward() }
    refreshTextStateSoon()
  }

  func keyboardSurface(_ surface: KeyboardSurfaceView, moveCursorVerticallyBy lines: Int) {
    lastReplacement = nil
    let offset = TrackpadCursor.verticalOffset(
      contextBefore: textDocumentProxy.documentContextBeforeInput,
      contextAfter: textDocumentProxy.documentContextAfterInput,
      direction: lines
    )
    if offset != 0 { textDocumentProxy.adjustTextPosition(byCharacterOffset: offset) }
  }

  func keyboardSurface(_ surface: KeyboardSurfaceView, adjustTextPositionBy offset: Int) {
    lastReplacement = nil
    textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
  }

  func keyboardSurfacePlayInputClick(_ surface: KeyboardSurfaceView) {
    // Follows the system "Keyboard Clicks" setting by itself; the surface has
    // already checked our own toggle.
    UIDevice.current.playInputClick()
  }

  func keyboardSurfaceMicrophoneTapped(_ surface: KeyboardSurfaceView) {
    microphoneTapped()
  }

  func keyboardSurface(
    _ surface: KeyboardSurfaceView,
    showInputModeListFrom button: UIButton,
    event: UIEvent
  ) {
    handleInputModeList(from: button, with: event)
  }
}
