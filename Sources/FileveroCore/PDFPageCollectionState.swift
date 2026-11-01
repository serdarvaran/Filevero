import PDFKit

/// Manages interactive PDF page ordering, rotations, duplications, deletions and pages added from other documents.
/// Every page keeps the document it came from (0 is the opened PDF) and its index in that document.
public struct PDFPageCollectionState {
    public private(set) var pages: [PDFPage] = []
    public private(set) var sourceIndexes: [Int] = []
    public private(set) var documentIndexes: [Int] = []
    public private(set) var selection: IndexSet = []

    public init() {}

    public var selectedPage: Int? { selection.first }
    public var hasSelection: Bool { !selection.isEmpty }
    public var canDelete: Bool { hasSelection && selection.count < pages.count }
    public var canMoveLeft: Bool { (selection.first ?? 0) > 0 }
    public var canMoveRight: Bool { selection.last.map { $0 < pages.count - 1 } ?? false }

    public var rotations: [Int: Int] {
        Dictionary(uniqueKeysWithValues: pages.enumerated().map { ($0.offset, $0.element.rotation) })
    }

    public mutating func reset(document: PDFDocument? = nil) {
        selection = []
        pages.removeAll(keepingCapacity: true)
        sourceIndexes.removeAll(keepingCapacity: true)
        documentIndexes.removeAll(keepingCapacity: true)
        guard let document else { return }
        append(document, as: 0, at: 0)
    }

    public mutating func select(_ index: Int) {
        selection = pages.indices.contains(index) ? [index] : []
    }

    public mutating func toggle(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
    }

    /// Selects every page between the first selected page and `index`.
    public mutating func extend(to index: Int) {
        guard pages.indices.contains(index) else { return }
        let anchor = selection.first ?? index
        selection = IndexSet(integersIn: min(anchor, index)...max(anchor, index))
    }

    public mutating func selectAll() {
        selection = IndexSet(pages.indices)
    }

    public mutating func rotateSelected() {
        for index in selection {
            guard let page = pages[index].copy() as? PDFPage else { continue }
            page.rotation = (page.rotation + 90) % 360
            pages[index] = page
        }
    }

    /// Places a copy right after each selected page; the originals stay selected.
    public mutating func duplicateSelected() {
        var shifted = IndexSet()
        for (offset, index) in selection.enumerated() {
            let position = index + offset
            guard let copy = pages[position].copy() as? PDFPage else { continue }
            pages.insert(copy, at: position + 1)
            sourceIndexes.insert(sourceIndexes[position], at: position + 1)
            documentIndexes.insert(documentIndexes[position], at: position + 1)
            shifted.insert(position)
        }
        selection = shifted
    }

    public mutating func deleteSelected() {
        guard canDelete else { return }
        for index in selection.reversed() {
            pages.remove(at: index)
            sourceIndexes.remove(at: index)
            documentIndexes.remove(at: index)
        }
        selection = []
    }

    public mutating func moveSelected(by offset: Int) {
        guard offset == -1 ? canMoveLeft : offset == 1 ? canMoveRight : false else { return }
        let order = offset == -1 ? Array(selection) : selection.reversed()
        for index in order {
            pages.swapAt(index, index + offset)
            sourceIndexes.swapAt(index, index + offset)
            documentIndexes.swapAt(index, index + offset)
        }
        selection = IndexSet(selection.map { $0 + offset })
    }

    /// Moves pages the way a list drag does: `destination` is an offset in the order before the move.
    public mutating func move(_ indexes: IndexSet, to destination: Int) {
        let moved = indexes.filteredIndexSet { pages.indices.contains($0) }
        guard !moved.isEmpty, (0...pages.count).contains(destination) else { return }
        let target = destination - moved.count(in: 0..<destination)
        let rows = pages.indices.map { (pages[$0], sourceIndexes[$0], documentIndexes[$0]) }
        var kept = rows.indices.filter { !moved.contains($0) }.map { rows[$0] }
        kept.insert(contentsOf: moved.map { rows[$0] }, at: target)
        pages = kept.map(\.0)
        sourceIndexes = kept.map(\.1)
        documentIndexes = kept.map(\.2)
        selection = IndexSet(integersIn: target..<(target + moved.count))
    }

    /// Adds every page of `document` after the selection (or at the end) and selects them.
    public mutating func insert(_ document: PDFDocument, as documentIndex: Int) {
        guard !pages.isEmpty else { return }
        append(document, as: documentIndex, at: (selection.last ?? pages.count - 1) + 1)
    }

    private mutating func append(_ document: PDFDocument, as documentIndex: Int, at position: Int) {
        var inserted = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            pages.insert(page, at: position + inserted)
            sourceIndexes.insert(index, at: position + inserted)
            documentIndexes.insert(documentIndex, at: position + inserted)
            inserted += 1
        }
        if documentIndex != 0 { selection = IndexSet(integersIn: position..<(position + inserted)) }
    }
}

// MARK: - Compatibility Bridge
public typealias PDFPageEditorState = PDFPageCollectionState
