import XCTest

@testable import FileveroCore

final class AppLocalizationTests: XCTestCase {
    func testEveryToolAndWindowPlacementHasTurkishCopy() {
        for source in Array(FeatureCatalog.toolNames.values) + ToolKind.allCases.map(\.title)
            + WindowPlacement.allCases.map(\.title)
        {
            XCTAssertNotEqual(AppLocalization.text(source, language: "tr"), source, source)
        }
        XCTAssertEqual(AppLocalization.text("Language", language: "tr"), "Dil")
        XCTAssertEqual(AppLocalization.text("Library", language: "tr"), "Kitaplık")
        XCTAssertEqual(AppLocalization.text("Pasted text", language: "tr"), "Yapıştırılan metin")
        XCTAssertEqual(AppLocalization.text("READ QR CODES", language: "tr"), "QR KODLARINI OKU")
        XCTAssertEqual(AppLocalization.text("Resize Image".uppercased(), language: "tr"), "GÖRSELİ BOYUTLANDIR")
    }
    func testTurkishUppercaseKeepsLatinProductAndKeyNames() {
        XCTAssertEqual(AppLocalization.text("SHOW FILEVERO IN FINDER", language: "tr"), "FILEVERO'YU FINDER'DA GÖSTER")
        XCTAssertEqual(AppLocalization.uppercased("Shift'e bas", language: "tr"), "SHIFT'E BAS")
        XCTAssertEqual(AppLocalization.uppercased("Görseli seç", language: "tr"), "GÖRSELİ SEÇ")
        XCTAssertEqual(AppLocalization.uppercased("Shift", language: "en"), "SHIFT")
    }
    func testFallbackAndFormattingKeepOriginalInput() {
        XCTAssertEqual(AppLocalization.normalizedLanguage(nil), "en")
        XCTAssertEqual(AppLocalization.normalizedLanguage("fr"), "en")
        XCTAssertEqual(AppLocalization.text("Library", language: "en"), "Library")
        XCTAssertTrue(AppLocalization.matches("Crop Image", query: "kırp", language: "tr"))
        XCTAssertTrue(AppLocalization.matches("Crop Image", query: "görsel", language: "tr"))
        XCTAssertEqual(AppLocalization.text("Home.png", language: "tr"), "Home.png")
        let path = "Türkçe {0} $1 \\ image.png"
        XCTAssertEqual(AppLocalization.text("Original size: " + path, language: "tr"), "Orijinal boyut: " + path)
        XCTAssertEqual(
            AppLocalization.text("Nicely done. 12 files are ready.", language: "tr"), "Hazır! 12 dosyan hazır.")
    }
    func testRuntimeUpdateStatusUsesTheLongestMatchingTemplate() {
        XCTAssertEqual(AppLocalization.text("Version 2.4.1 is available", language: "tr"), "2.4.1 sürümü hazır")
        XCTAssertEqual(AppLocalization.text("Version 2.4.1", language: "tr"), "Sürüm 2.4.1")
        XCTAssertEqual(AppLocalization.text("3 QR codes found.", language: "tr"), "3 QR kodu bulundu.")
    }
    func testRuntimeTemplatesAndCountedCopyTranslate() {
        let expected = [
            "Download · instagram.com": "İndirme · instagram.com",
            "Each image: 1.5 s": "Her görsel: 1.5 sn",
            "Float · 1 file": "Yüzen Pencere · 1 dosya",
            "Float · 4 files": "Yüzen Pencere · 4 dosya",
            "Photo 2 of 5…": "Fotoğraf 2/5…",
            "1 video item is not included. Only photos will be saved.":
                "1 video öğesi dahil edilmedi. Yalnızca fotoğraflar kaydedilecek.",
            "3 video items are not included. Only photos will be saved.":
                "3 video öğesi dahil edilmedi. Yalnızca fotoğraflar kaydedilecek.",
            "1 split point": "1 bölme noktası",
            "3 split points": "3 bölme noktası",
            "1 area selected": "1 alan seçildi",
            "2 areas selected": "2 alan seçildi",
            "Save 1 frame": "1 kare kaydet",
            "Save 6 frames": "6 kare kaydet",
            "4 ready to paste.": "4 kod yapıştırmaya hazır.",
            "Opened in Terminal.": "Terminal ile açıldı.",
            "Could not open Report.pdf.": "Report.pdf açılamadı.",
            "Kırp timeline": "Kırp zaman çizelgesi",
            "2.4 MB · 35% smaller": "2.4 MB · %35 daha küçük",
            "Saved size: 2.4 MB": "Kaydedilen boyut: 2.4 MB",
        ]
        for (source, translation) in expected {
            XCTAssertEqual(AppLocalization.text(source, language: "tr"), translation, source)
        }
        for broad in ["Photo 12", "Preview Audio.wav", "Remove background with Filevero"] {
            XCTAssertEqual(AppLocalization.text(broad, language: "tr"), broad, "Overly broad template matched: \(broad)")
        }
    }
    func testDatesFollowAppLanguageInsteadOfSystemLocale() {
        let now = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")!
        let earlier = Calendar(identifier: .gregorian).date(byAdding: .month, value: -9, to: now)!
        XCTAssertEqual(AppLocalization.relativeDate(earlier, relativeTo: now, language: "en"), "9 months ago")
        XCTAssertEqual(AppLocalization.relativeDate(earlier, relativeTo: now, language: "tr"), "9 ay önce")
        XCTAssertTrue(AppLocalization.dateTime(now, language: "en").contains("Oct"))
        XCTAssertTrue(AppLocalization.dateTime(now, language: "tr").contains("Eki"))
    }
    func testCatalogPlaceholdersMatchWithoutChangingFormatsOrShortcuts() {
        let marker = try! NSRegularExpression(pattern: #"\{[0-9]\}"#)
        func tokens(_ value: String) -> [String] {
            marker.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
                Range($0.range, in: value).map { String(value[$0]) }
            }.sorted()
        }
        for (source, translation) in AppLocalization.turkish {
            XCTAssertFalse(translation.isEmpty, source)
            XCTAssertEqual(tokens(source), tokens(translation), source)
        }
        for code in ["png", "MP4", "Ctrl+Shift", "⌘S", "00:01.250"] {
            XCTAssertEqual(AppLocalization.text(code, language: "tr"), code)
        }
    }
}
