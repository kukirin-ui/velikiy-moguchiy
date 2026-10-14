import XCTest

@testable import VelikiyMoguchiy

final class TranscriptFormatterTests: XCTestCase {
  func testCleanerRemovesCommonModelWrappers() {
    XCTAssertEqual(
      TranscriptFormatter.cleaned("  Transcript: \"Meet me at five.\"  "),
      "Meet me at five."
    )
    XCTAssertEqual(
      TranscriptFormatter.cleaned("```\nA fenced transcript.\n```"),
      "A fenced transcript."
    )
  }

  func testInsertionAddsSpaceAfterExistingWord() {
    XCTAssertEqual(
      TranscriptFormatter.textForInsertion("next thought", contextBefore: "Existing"),
      " next thought"
    )
    XCTAssertEqual(
      TranscriptFormatter.textForInsertion("next thought", contextBefore: "Existing "),
      "next thought"
    )
    XCTAssertEqual(
      TranscriptFormatter.textForInsertion(".", contextBefore: "Existing"),
      "."
    )
  }
}
