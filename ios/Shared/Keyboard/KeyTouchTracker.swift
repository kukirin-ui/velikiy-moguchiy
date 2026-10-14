import CoreGraphics
import Foundation

// Touch handling for the key grid, kept free of UIKit so every decision is unit
// tested. The system keyboard works the same way: one tracker for the whole
// grid instead of one control per key, so
//   - a touch lands on the nearest key (no dead zones in the gaps and margins),
//   - a second finger commits the first finger's key at once (fast two-thumb
//     typing loses nothing),
//   - sliding off a key moves to the key under the finger, and the key under
//     the finger on release is the one that is typed,
//   - the space bar turns into a trackpad only after a long press; a thumb
//     that drifts along it while typing fast still types a space.

struct KeyID: Hashable {
  let row: Int
  let column: Int
}

/// How a key reacts to a touch.
enum KeyTouchKind: Equatable {
  /// Letters, digits, punctuation: typed on release over the key under the
  /// finger, or as soon as another finger lands.
  case character
  /// The space bar: typed on release over itself; a long press moves the cursor.
  case space
  /// ⌫: acts on touch-down and repeats while held.
  case delete
  /// Shift, page, return, microphone: acts on release over the same key.
  case function
}

struct KeyTarget: Equatable {
  let id: KeyID
  let frame: CGRect
  let kind: KeyTouchKind
  /// Disabled keys swallow the touch without acting (dictation locks typing).
  let isEnabled: Bool
  /// Whether the key opens an accent panel on a long press.
  let hasAlternates: Bool

  init(
    id: KeyID, frame: CGRect, kind: KeyTouchKind, isEnabled: Bool = true,
    hasAlternates: Bool = false
  ) {
    self.id = id
    self.frame = frame
    self.kind = kind
    self.isEnabled = isEnabled
    self.hasAlternates = hasAlternates
  }
}

enum KeyHitTester {
  /// A touch farther than this from every key (outside the keyboard) hits nothing.
  static let maximumDistance: CGFloat = 48

  /// The key nearest to `point`: the one containing it, otherwise the one at the
  /// smallest distance, ties broken by distance to the key's center.
  static func nearestKey(to point: CGPoint, in targets: [KeyTarget]) -> KeyTarget? {
    var best: (target: KeyTarget, distance: CGFloat, centerDistance: CGFloat)?
    for target in targets {
      let frame = target.frame
      let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
      let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
      let distance = (dx * dx + dy * dy).squareRoot()
      let centerDistance = hypot(frame.midX - point.x, frame.midY - point.y)
      if let current = best {
        if distance < current.distance - 0.001
          || (abs(distance - current.distance) <= 0.001
            && centerDistance < current.centerDistance)
        {
          best = (target, distance, centerDistance)
        }
      } else {
        best = (target, distance, centerDistance)
      }
    }
    guard let best, best.distance <= maximumDistance else { return nil }
    return best.target
  }
}

/// What the surface must do in response to a touch event.
enum KeyTouchOutput: Equatable {
  /// A finger went down on a key: highlight/feedback/balloon.
  case pressed(touch: Int, key: KeyID)
  /// The finger slid from one key to another (or off every key).
  case slid(touch: Int, from: KeyID, to: KeyID?)
  /// Type or perform this key now.
  case commit(touch: Int, key: KeyID)
  /// The finger left the key without typing anything.
  case released(touch: Int, key: KeyID)
  /// ⌫ finger went down (act and start repeating) / up (stop repeating).
  case deleteBegan(touch: Int)
  case deleteEnded(touch: Int)
  /// Long press recognised on a letter with alternates / on the space bar.
  case alternatesBegan(touch: Int, key: KeyID)
  case alternatesMoved(touch: Int, point: CGPoint)
  case alternatesEnded(touch: Int, point: CGPoint)
  /// The system took the touch away: close the panel, type nothing.
  case alternatesCancelled(touch: Int)
  case trackpadBegan(touch: Int)
  case trackpadMoved(touch: Int, point: CGPoint)
  case trackpadEnded(touch: Int)
}

struct KeyTouchTracker {
  enum Mode: Equatable {
    case normal
    case alternates
    case trackpad
  }

  private struct Touch {
    var origin: KeyTarget
    var current: KeyTarget?
    var mode: Mode = .normal
    var committed = false
  }

  var targets: [KeyTarget] = []
  private var touches: [Int: Touch] = [:]

  var activeTouchCount: Int { touches.count }

  func target(for id: KeyID) -> KeyTarget? {
    targets.first { $0.id == id }
  }

  func currentKey(ofTouch touch: Int) -> KeyID? {
    touches[touch]?.current?.id
  }

  func mode(ofTouch touch: Int) -> Mode? {
    touches[touch]?.mode
  }

  func originKey(ofTouch touch: Int) -> KeyID? {
    touches[touch]?.origin.id
  }

  // MARK: Events

  mutating func began(touch: Int, at point: CGPoint) -> [KeyTouchOutput] {
    var output: [KeyTouchOutput] = []
    guard let hit = KeyHitTester.nearestKey(to: point, in: targets) else { return output }

    // A new finger settles the keys the other fingers are still holding.
    for id in touches.keys.sorted() {
      guard var other = touches[id], other.mode == .normal, !other.committed,
        let current = other.current, current.isEnabled,
        current.kind == .character || current.kind == .space
      else { continue }
      other.committed = true
      touches[id] = other
      output.append(.commit(touch: id, key: current.id))
    }

    var newTouch = Touch(origin: hit, current: hit)
    guard hit.isEnabled else {
      // Swallowed: the touch exists so its release is not misread, but it acts on nothing.
      newTouch.committed = true
      touches[touch] = newTouch
      return output
    }
    touches[touch] = newTouch
    output.append(.pressed(touch: touch, key: hit.id))
    if hit.kind == .delete {
      touches[touch]?.committed = true
      output.append(.deleteBegan(touch: touch))
    }
    return output
  }

  mutating func moved(touch: Int, to point: CGPoint) -> [KeyTouchOutput] {
    guard var state = touches[touch] else { return [] }
    switch state.mode {
    case .alternates:
      return [.alternatesMoved(touch: touch, point: point)]
    case .trackpad:
      return [.trackpadMoved(touch: touch, point: point)]
    case .normal:
      break
    }
    if state.committed { return [] }

    let hit = KeyHitTester.nearestKey(to: point, in: targets)
    guard hit?.id != state.current?.id else { return [] }
    let previous = state.current
    state.current = hit
    touches[touch] = state
    // Only letters follow a sliding finger; function keys stay pressed or not.
    guard let previous else { return [] }
    return [.slid(touch: touch, from: previous.id, to: hit?.id)]
  }

  mutating func ended(touch: Int, at point: CGPoint) -> [KeyTouchOutput] {
    guard var state = touches.removeValue(forKey: touch) else { return [] }
    switch state.mode {
    case .alternates:
      return [.alternatesEnded(touch: touch, point: point)]
    case .trackpad:
      return [.trackpadEnded(touch: touch)]
    case .normal:
      break
    }
    if state.origin.kind == .delete {
      return [.released(touch: touch, key: state.origin.id), .deleteEnded(touch: touch)]
    }
    if state.committed {
      return [.released(touch: touch, key: state.current?.id ?? state.origin.id)]
    }
    // The key under the finger now decides, not the one it landed on.
    let final = KeyHitTester.nearestKey(to: point, in: targets)
    state.current = final
    let visible = state.current?.id ?? state.origin.id
    guard let final, final.isEnabled else {
      return [.released(touch: touch, key: visible)]
    }
    switch state.origin.kind {
    case .character:
      if final.kind == .character {
        return [.commit(touch: touch, key: final.id)]
      }
      return [.released(touch: touch, key: visible)]
    case .space, .function:
      if final.id == state.origin.id {
        return [.commit(touch: touch, key: final.id)]
      }
      return [.released(touch: touch, key: state.origin.id)]
    case .delete:
      return []
    }
  }

  mutating func cancelled(touch: Int) -> [KeyTouchOutput] {
    guard let state = touches.removeValue(forKey: touch) else { return [] }
    switch state.mode {
    case .alternates:
      return [.alternatesCancelled(touch: touch)]
    case .trackpad:
      return [.trackpadEnded(touch: touch)]
    case .normal:
      var output: [KeyTouchOutput] = [
        .released(touch: touch, key: state.current?.id ?? state.origin.id)
      ]
      if state.origin.kind == .delete { output.append(.deleteEnded(touch: touch)) }
      return output
    }
  }

  // MARK: Long presses (timers live in the surface)

  /// The finger has rested on a letter with alternates long enough.
  mutating func beginAlternates(touch: Int) -> [KeyTouchOutput] {
    guard var state = touches[touch], state.mode == .normal, !state.committed,
      let current = state.current, current.hasAlternates, current.id == state.origin.id
    else { return [] }
    state.mode = .alternates
    touches[touch] = state
    return [.alternatesBegan(touch: touch, key: current.id)]
  }

  /// The finger has rested on the space bar long enough: trackpad mode.
  mutating func beginTrackpad(touch: Int) -> [KeyTouchOutput] {
    guard var state = touches[touch], state.mode == .normal, !state.committed,
      state.origin.kind == .space, state.current?.id == state.origin.id
    else { return [] }
    state.mode = .trackpad
    touches[touch] = state
    return [
      .released(touch: touch, key: state.origin.id),
      .trackpadBegan(touch: touch),
    ]
  }

  mutating func reset() {
    touches.removeAll()
  }
}
