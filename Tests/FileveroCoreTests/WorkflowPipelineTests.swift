import CoreGraphics
import ImageIO
import XCTest

@testable import FileveroCore

final class WorkflowTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = try OutputFiles.temporaryDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func photo(_ name: String, width: Int = 3000, height: Int = 2000) throws -> URL {
        let url = root.appendingPathComponent(name)
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let metadata =
            [
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Ayşe Yılmaz"],
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 41.0, kCGImagePropertyGPSLatitudeRef: "N",
                ],
            ] as CFDictionary
        try ImageEngine.write(XCTUnwrap(context.makeImage()), to: url, quality: 0.9, metadata: metadata)
        return url
    }
    private func options(template: String? = nil) -> OperationOptions {
        var options = OperationOptions()
        options.outputDirectory = root.appendingPathComponent("Out", isDirectory: true)
        options.outputNameTemplate = template
        options.revealInFinder = false
        return options
    }
    private func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }
    private var outFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Out").path)) ?? []).sorted()
    }

    func testResizeWebPAndMetadataRemovalPublishOnlyTheFinalFileNamedAfterTheOriginal() throws {
        let input = try photo("Tatil Fotoğrafı.jpg")
        let before = try Data(contentsOf: input)
        XCTAssertNotNil((try properties(input))[kCGImagePropertyGPSDictionary])
        let workflow = Workflow(
            name: "Web için hazırla", steps: [.resize(maxDimension: 1600), .convert(format: "webp"), .removeMetadata])
        XCTAssertTrue(workflow.accepts([input]))
        let outputs = try WorkflowEngine.run([input], workflow: workflow, options: options(), token: .init())
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["Tatil Fotoğrafı.webp"])
        XCTAssertEqual(outFiles, ["Tatil Fotoğrafı.webp"])
        let result = try properties(outputs[0])
        XCTAssertEqual(result[kCGImagePropertyPixelWidth] as? Int, 1600)
        XCTAssertEqual(result[kCGImagePropertyPixelHeight] as? Int, 1067)
        XCTAssertNil(result[kCGImagePropertyGPSDictionary])
        XCTAssertNil((result[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist])
        XCTAssertEqual(try Data(contentsOf: input), before)
    }

    func testAFailingLaterStepLeavesNoOutputOrIntermediateFile() throws {
        let input = try photo("Kaynak.png", width: 400, height: 300)
        for steps: [WorkflowStep] in [
            [.convert(format: "jpg"), .convert(format: "mp3")], [.convert(format: "jpg"), .resize(maxDimension: 0)],
        ] {
            XCTAssertThrowsError(
                try WorkflowEngine.run(
                    [input], workflow: Workflow(name: "Bozuk", steps: steps), options: options(), token: .init())
            ) { error in
                guard case FileveroError.invalidInput = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(outFiles, [])
        }
        XCTAssertThrowsError(
            try WorkflowEngine.run(
                [input], workflow: Workflow(name: "Boş", steps: []), options: options(), token: .init()))
        let cancelled = CancellationToken()
        cancelled.cancel()
        XCTAssertThrowsError(
            try WorkflowEngine.run(
                [input], workflow: Workflow(name: "İptal", steps: [.convert(format: "jpg")]), options: options(),
                token: cancelled))
        XCTAssertEqual(outFiles, [])
    }

    func testSmallImagesAreNotEnlargedAndOnlyTheFirstStepGatesAcceptance() throws {
        let small = try photo("Küçük.png", width: 300, height: 200)
        let outputs = try WorkflowEngine.run(
            [small], workflow: Workflow(name: "Sığdır", steps: [.resize(maxDimension: 1600)]), options: options(),
            token: .init())
        XCTAssertEqual(try properties(outputs[0])[kCGImagePropertyPixelWidth] as? Int, 300)
        XCTAssertEqual(outputs[0].lastPathComponent, "Küçük.png")
        let pdf = root.appendingPathComponent("Belge.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        XCTAssertFalse(Workflow(name: "Görsel", steps: [.resize(maxDimension: 100)]).accepts([pdf]))
        XCTAssertFalse(Workflow(name: "Boş", steps: []).accepts([small]))
    }

    func testQueuedWorkflowRunsPerFileAndSurvivesStorage() throws {
        let inputs = try ["Kış.png", "Yaz.png"].map { try photo($0, width: 500, height: 400) }
        var state = JobQueueState()
        let workflow = Workflow(name: "JPG", steps: [.convert(format: "jpg"), .removeMetadata])
        let batch = state.enqueue(inputs, workflow: workflow, options: options(template: "{n}-{name}"))
        let restored = try JSONDecoder().decode(JobQueueState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.jobs(in: batch).map(\.workflow), [workflow, workflow])
        XCTAssertEqual(restored.jobs(in: batch).map(\.operationTitle), ["JPG", "JPG"])
        while let job = state.next {
            state.update(job.id, to: .running)
            state.update(job.id, to: .done(try job.run(token: .init())))
        }
        XCTAssertEqual(outFiles, ["1-Kış.jpg", "2-Yaz.jpg"].map { $0.precomposedStringWithCanonicalMapping })
    }
}
