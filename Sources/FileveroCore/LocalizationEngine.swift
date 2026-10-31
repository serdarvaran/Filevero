import Foundation

/// Application UI localization engine providing dynamic language switching (English/Turkish),
/// casing rules complying with Turkish orthography, and template string replacement.
public enum LocalizationEngine {
    public static let supportedLanguages = ["en", "tr"]

    public static func normalizedLanguage(_ value: String?) -> String {
        value == "tr" ? "tr" : "en"
    }

    /// Tests whether a source string or its localized translation matches a search query.
    public static func matches(_ source: String, query: String, language: String) -> Bool {
        let locale = Locale(identifier: normalizedLanguage(language))
        return [source, text(source, language: language)].contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
        }
    }

    /// Formats a relative date adhering to the active UI language.
    public static func relativeDate(_ date: Date, relativeTo now: Date = Date(), language: String) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: normalizedLanguage(language))
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Formats an abbreviated date-time string respecting the active language.
    public static func dateTime(_ date: Date, language: String) -> String {
        date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened)
                .locale(Locale(identifier: normalizedLanguage(language)))
        )
    }

    public static let turkish: [String: String] = {
        guard let url = CoreResources.url(forResource: "Turkish", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return values
    }()

    /// Technical terms and modifier keys that retain Latin capitalization (e.g. SHIFT, not SHİFT).
    public static let latinWords: Set<String> = {
        guard let url = CoreResources.url(forResource: "LatinWords", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let words = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(words)
    }()

    /// Converts UI text to upper case applying Turkish orthographic rules, preserving `latinWords`.
    public static func uppercased(_ value: String, language: String) -> String {
        let latinLocale = Locale(identifier: "en_US_POSIX")
        guard normalizedLanguage(language) == "tr" else {
            return value.uppercased(with: latinLocale)
        }
        
        let turkishLocale = Locale(identifier: "tr_TR")
        var result = ""
        var currentWord = ""
        
        func flushWord() {
            guard !currentWord.isEmpty else { return }
            result += latinWords.contains(currentWord)
                ? currentWord.uppercased(with: latinLocale)
                : currentWord.uppercased(with: turkishLocale)
            currentWord = ""
        }
        
        for char in value {
            if char.isLetter {
                currentWord.append(char)
            } else {
                flushWord()
                result.append(char)
            }
        }
        flushWord()
        return result
    }

    private static let uppercaseLookup = Dictionary(
        turkish.filter { !$0.key.contains("{0}") }.map {
            ($0.key.uppercased(with: Locale(identifier: "en_US_POSIX")), uppercased($0.value, language: "tr"))
        },
        uniquingKeysWith: { first, _ in first }
    )

    private struct TemplatePattern {
        let regex: NSRegularExpression
        let replacement: String
    }

    private static let dynamicTemplates: [TemplatePattern] = turkish
        .filter { $0.key.contains("{0}") }
        .sorted { $0.key.count > $1.key.count }
        .compactMap { source, target in
            var escapedPattern = NSRegularExpression.escapedPattern(for: source)
            for idx in 0..<10 {
                escapedPattern = escapedPattern.replacingOccurrences(
                    of: NSRegularExpression.escapedPattern(for: "{\(idx)}"),
                    with: "(.*?)"
                )
            }
            guard let regex = try? NSRegularExpression(
                pattern: "^" + escapedPattern + "$",
                options: [.dotMatchesLineSeparators]
            ) else { return nil }
            return TemplatePattern(regex: regex, replacement: target)
        }

    /// Resolves the localized display text for the specified source string and target language.
    public static func text(_ source: String, language: String) -> String {
        guard normalizedLanguage(language) == "tr" else { return source }
        if let directMatch = turkish[source] ?? uppercaseLookup[source] {
            return directMatch
        }
        guard source.count < 16_384 else { return source }
        
        for template in dynamicTemplates {
            guard let match = template.regex.firstMatch(
                in: source,
                range: NSRange(source.startIndex..., in: source)
            ) else { continue }
            
            guard let marker = try? NSRegularExpression(pattern: #"\{([0-9])\}"#) else { continue }
            var rendered = template.replacement
            
            for token in marker.matches(
                in: template.replacement,
                range: NSRange(template.replacement.startIndex..., in: template.replacement)
            ).reversed() {
                guard let indexRange = Range(token.range(at: 1), in: template.replacement),
                      let index = Int(template.replacement[indexRange]),
                      index + 1 < match.numberOfRanges,
                      let valueRange = Range(match.range(at: index + 1), in: source),
                      let replacementRange = Range(token.range, in: rendered)
                else { continue }
                
                rendered.replaceSubrange(replacementRange, with: source[valueRange])
            }
            return rendered
        }
        return source
    }
}

public typealias AppLocalization = LocalizationEngine

