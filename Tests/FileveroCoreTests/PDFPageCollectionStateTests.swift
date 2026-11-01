import PDFKit
import XCTest

@testable import FileveroCore

final class PDFPageEditorStateTests: XCTestCase {
    private func document(pages: Int) -> PDFDocument {
        let document = PDFDocument()
        for index in 0..<pages { document.insert(PDFPage(), at: index) }
        return document
    }
    func testResetAfterDuplicatingClearsOutOfRangeSelection() {
        let original = document(pages: 2)
        var editor = PDFPageEditorState()
        editor.reset(document: original)
        editor.select(1)
        editor.duplicateSelected()
        editor.select(2)
        editor.duplicateSelected()
        editor.select(3)
        XCTAssertEqual(editor.pages.count, 4)
        editor.reset(document: original)
        XCTAssertNil(editor.selectedPage)
        editor.rotateSelected()
        editor.duplicateSelected()
        editor.deleteSelected()
        editor.moveSelected(by: -1)
        XCTAssertEqual(editor.pages.count, 2)
        XCTAssertEqual(editor.sourceIndexes, [0, 1])
        XCTAssertEqual(editor.pages.map(\.rotation), [0, 0])
    }
    func testReorderingKeepsSourceAndRotationAttachedToEachPage() {
        var editor = PDFPageEditorState()
        editor.reset(document: document(pages: 3))
        editor.select(1)
        editor.rotateSelected()
        editor.duplicateSelected()
        editor.select(2)
        editor.moveSelected(by: 1)
        XCTAssertEqual(editor.sourceIndexes, [0, 1, 2, 1])
        XCTAssertEqual(editor.rotations, [0: 0, 1: 90, 2: 0, 3: 90])
        editor.deleteSelected()
        XCTAssertEqual(editor.sourceIndexes, [0, 1, 2])
        XCTAssertNil(editor.selectedPage)
    }
    func testInvalidSelectionAndDocumentReplacementCannotMutateOtherPages() {
        var editor = PDFPageEditorState()
        editor.reset(document: document(pages: 1))
        editor.select(Int.max)
        editor.rotateSelected()
        editor.duplicateSelected()
        editor.deleteSelected()
        editor.moveSelected(by: 1)
        XCTAssertNil(editor.selectedPage)
        editor.select(0)
        editor.deleteSelected()
        editor.moveSelected(by: -1)
        editor.moveSelected(by: 1)
        XCTAssertEqual(editor.pages.count, 1)
        editor.reset()
        XCTAssertTrue(editor.pages.isEmpty)
        XCTAssertTrue(editor.sourceIndexes.isEmpty)
        XCTAssertFalse(editor.hasSelection)
    }
    func testMultipleSelectionRotatesDuplicatesAndDeletesTogether() {
        var editor = PDFPageEditorState()
        editor.reset(document: document(pages: 4))
        editor.select(1)
        editor.toggle(3)
        XCTAssertEqual(editor.selection, [1, 3])
        editor.rotateSelected()
        XCTAssertEqual(editor.pages.map(\.rotation), [0, 90, 0, 90])
        editor.duplicateSelected()
        XCTAssertEqual(editor.sourceIndexes, [0, 1, 1, 2, 3, 3])
        XCTAssertEqual(editor.selection, [1, 4])
        editor.extend(to: 5)
        XCTAssertEqual(editor.selection, [1, 2, 3, 4, 5])
        XCTAssertTrue(editor.canDelete)
        editor.deleteSelected()
        XCTAssertEqual(editor.sourceIndexes, [0])
        editor.selectAll()
        XCTAssertFalse(editor.canDelete, "the last page cannot be deleted")
    }

    func testDraggingAndArrowMovesCarryTheWholeSelection() {
        var editor = PDFPageEditorState()
        editor.reset(document: document(pages: 5))
        editor.select(0)
        editor.toggle(2)
        editor.moveSelected(by: 1)
        XCTAssertEqual(editor.sourceIndexes, [1, 0, 3, 2, 4])
        XCTAssertEqual(editor.selection, [1, 3])
        editor.move([1, 3], to: 5)
        XCTAssertEqual(editor.sourceIndexes, [1, 3, 4, 0, 2])
        XCTAssertEqual(editor.selection, [3, 4])
        XCTAssertFalse(editor.canMoveRight)
        editor.move([4], to: 0)
        XCTAssertEqual(editor.sourceIndexes, [2, 1, 3, 4, 0])
        XCTAssertEqual(editor.selection, [0])
    }

    func testAddedDocumentPagesFollowTheSelectionAndRememberTheirDocument() {
        var editor = PDFPageEditorState()
        editor.reset(document: document(pages: 3))
        editor.select(0)
        editor.insert(document(pages: 2), as: 1)
        XCTAssertEqual(editor.sourceIndexes, [0, 0, 1, 1, 2])
        XCTAssertEqual(editor.documentIndexes, [0, 1, 1, 0, 0])
        XCTAssertEqual(editor.selection, [1, 2])
        editor.reset()
        editor.insert(document(pages: 1), as: 1)
        XCTAssertTrue(editor.pages.isEmpty, "pages are only added to an open document")
    }
}
