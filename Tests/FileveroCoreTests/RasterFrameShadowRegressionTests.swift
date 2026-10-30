import CoreGraphics
import XCTest

@testable import FileveroCore

final class RasterFrameShadowRegressionTests: XCTestCase {
    private func image(_ width: Int, _ height: Int, draw: (CGContext) -> Void) throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    /// RGBA at a top-left based pixel coordinate.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return data
    }

    private func framed(_ input: CGImage) throws -> CGImage {
        var settings = ImageFrameOptions()
        settings.padding = 40
        settings.cornerRadius = 6
        settings.shadowRadius = 12
        settings.shadowOpacity = 0.8
        settings.backgroundColor = "#FFFFFF"
        var options = OperationOptions()
        options.imageFrame = settings
        return try ImageEngine.preview(input, tool: .frameImage, options: options)
    }

    func testShadowDoesNotFillTransparentAreasOfTheImage() throws {
        let cutout = try image(80, 60) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
            context.clear(CGRect(x: 10, y: 10, width: 60, height: 40))
        }
        let output = try framed(cutout)
        XCTAssertEqual(output.width, 160)
        XCTAssertEqual(output.height, 140)
        XCTAssertEqual(try pixel(output, 80, 70), [255, 255, 255, 255], "The transparent centre shows the backdrop")
        let border = try pixel(output, 45, 70)
        XCTAssertTrue(border[0] < 40 && border[2] > 200, "The opaque border is drawn: \(border)")
    }

    func testOpaqueImageStillCastsAShadow() throws {
        let photo = try image(80, 60) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }
        let output = try framed(photo)
        let centre = try pixel(output, 80, 70)
        XCTAssertTrue(centre[0] < 40 && centre[2] > 200, "The image is drawn: \(centre)")
        let belowImage = try pixel(output, 80, 104)
        XCTAssertLessThan(belowImage[0], 200, "A shadow darkens the backdrop under the image: \(belowImage)")
        XCTAssertEqual(try pixel(output, 2, 2), [255, 255, 255, 255])
    }
}
