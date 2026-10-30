import PDFKit

/// Manages interactive PDF page ordering, rotations, duplications, and deletions.
/// Maintains 1-to-1 mapping with underlying source document indexes.
public struct PDFPageCollectionState {
    public private(set) var pages: [PDFPage] = []
    public private(set) var sourceIndexes: [Int] = []
    public private(set) var selectedPage: Int?

    public init() {}

    public var hasSelection: Bool {
        selectedPage.map { pages.indices.contains($0) } ?? false
    }

    public var canDelete: Bool {
        hasSelection && pages.count > 1
    }

    public var canMoveLeft: Bool {
        hasSelection && (selectedPage ?? 0) > 0
    }

    public var canMoveRight: Bool {
        hasSelection && (selectedPage ?? 0) < pages.count - 1
    }

    public var rotations: [Int: Int] {
        Dictionary(uniqueKeysWithValues: pages.enumerated().map { ($0.offset, $0.element.rotation) })
    }

    public mutating func reset(document: PDFDocument? = nil) {
        selectedPage = nil
        pages.removeAll(keepingCapacity: true)
        sourceIndexes.removeAll(keepingCapacity: true)
        guard let document else { return }

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            pages.append(page)
            sourceIndexes.append(index)
        }
    }

    public mutating func select(_ index: Int) {
        selectedPage = pages.indices.contains(index) ? index : nil
    }

    public mutating func rotateSelected() {
        guard let index = selectedPage, pages.indices.contains(index),
              let page = pages[index].copy() as? PDFPage else {
            return
        }
        page.rotation = (page.rotation + 90) % 360
        pages[index] = page
    }

    public mutating func duplicateSelected() {
        guard let index = selectedPage,
              pages.indices.contains(index),
              sourceIndexes.indices.contains(index),
              let copy = pages[index].copy() as? PDFPage else {
            return
        }
        pages.insert(copy, at: index + 1)
        sourceIndexes.insert(sourceIndexes[index], at: index + 1)
    }

    public mutating func deleteSelected() {
        guard let index = selectedPage, canDelete, sourceIndexes.indices.contains(index) else { return }
        selectedPage = nil
        pages.remove(at: index)
        sourceIndexes.remove(at: index)
    }

    public mutating func moveSelected(by offset: Int) {
        guard offset == -1 || offset == 1,
              let index = selectedPage,
              pages.indices.contains(index) else {
            return
        }
        let targetIndex = index + offset
        guard pages.indices.contains(targetIndex),
              sourceIndexes.indices.contains(index),
              sourceIndexes.indices.contains(targetIndex) else {
            return
        }
        pages.swapAt(index, targetIndex)
        sourceIndexes.swapAt(index, targetIndex)
        selectedPage = targetIndex
    }
}

// MARK: - Compatibility Bridge
public typealias PDFPageEditorState = PDFPageCollectionState

