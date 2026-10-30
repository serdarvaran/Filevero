import ImageIO
import XCTest

@testable import FileveroCore

final class ImageLocationRemovalTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws { folder = try OutputFiles.temporaryDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    @discardableResult private func exif(_ arguments: [String]) throws -> Data {
        let script = try Dependencies.executable("exiftool")
        return try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/perl"), [script.path, "-config", ""] + arguments)
            .output
    }

    private func photo() throws -> URL {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let url = folder.appendingPathComponent("trip.jpg")
        try ImageEngine.write(XCTUnwrap(context.makeImage()), to: url, quality: 0.8)
        return url
    }

    func testRemoveLocationClearsGPSIPTCAndXMPLocationFields() throws {
        guard (try? Dependencies.executable("exiftool")) != nil else { throw XCTSkip("ExifTool is not installed.") }
        let source = try photo()
        let packet = folder.appendingPathComponent("custom.xmp")
        try Data(
            "<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'><rdf:Description rdf:about='' xmlns:trip='https://example.com/trip/'><trip:GpsLatitude>41.0</trip:GpsLatitude><trip:Note>Keep this</trip:Note></rdf:Description></rdf:RDF></x:xmpmeta>"
                .utf8
        ).write(to: packet)
        try exif(["-overwrite_original", "-XMP<=" + packet.path, source.path])
        try exif([
            "-overwrite_original", "-Make=Filevero Test", "-GPSLatitude=41", "-GPSLatitudeRef=N", "-GPSLongitude=29",
            "-GPSLongitudeRef=E", "-XMP-exif:GPSLatitude=41N", "-XMP-exif:GPSLongitude=29E",
            "-XMP-photoshop:City=Istanbul", "-XMP-photoshop:State=Istanbul", "-XMP-photoshop:Country=Turkey",
            "-XMP-iptcCore:Location=Moda", "-XMP-iptcCore:CountryCode=TR", "-XMP-iptcExt:LocationCreatedCity=Istanbul",
            "-XMP-iptcExt:LocationShownCity=Ankara", "-IPTC:City=Istanbul", "-IPTC:Sub-location=Moda",
            "-IPTC:Province-State=Istanbul", "-IPTC:Country-PrimaryLocationName=Turkey",
            "-IPTC:Country-PrimaryLocationCode=TUR", "-IPTC:ContentLocationName=Bosphorus", source.path,
        ])
        let before = ImageEngine.metadata(source)
        for key in ["{GPS}.Latitude", "{IPTC}.City", "{XMP-photoshop}.City", "{XMP-iptcCore}.Location", "{XMP-trip}.GpsLatitude"] {
            XCTAssertNotNil(before[key], "fixture is missing \(key)")
        }

        var changes = ImageMetadataOptions()
        changes.removeLocation = true
        let output = try ImageMetadataEngine.edit(source, changes: changes, options: OperationOptions(), token: .init())

        let dump = String(decoding: try exif(["-G1", "-s", "-a", "-n", output.path]), as: UTF8.self)
        for leaked in ["Istanbul", "Ankara", "Moda", "Bosphorus", "Turkey", "TUR", "41", "29"] {
            XCTAssertFalse(dump.contains(": \(leaked)"), "\(leaked) is still present:\n\(dump)")
        }
        let after = ImageEngine.metadata(output)
        XCTAssertNil(after.keys.first { $0.lowercased().contains("gps") })
        XCTAssertEqual(after["{TIFF}.Make"], "Filevero Test")
        XCTAssertEqual(after["{XMP-trip}.Note"], "Keep this")
    }
}
