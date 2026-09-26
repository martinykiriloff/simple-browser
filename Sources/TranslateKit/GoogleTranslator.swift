import Foundation

/// A language Google Translate can translate into.
public struct TranslationLanguage: Hashable, Sendable, Identifiable {
    /// Google's code: `de`, `zh-CN`, `mni-Mtei`.
    public let code: String
    public var id: String { code }

    public init(code: String) { self.code = code }

    /// In the user's own language: "German", "Chinese (China)".
    public var name: String {
        if let special = Self.specialNames[code] { return special }
        let name = Locale.current.localizedString(forIdentifier: code.replacingOccurrences(of: "-", with: "_")) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Where Foundation's name is missing or reads oddly.
    private static let specialNames: [String: String] = [
        "mni-Mtei": "Manipuri (Meitei Mayek)", "zh-CN": "Chinese (Simplified)", "zh-TW": "Chinese (Traditional)",
        "gom": "Konkani", "ckb": "Kurdish (Sorani)", "ku": "Kurdish (Kurmanji)", "lus": "Mizo", "kri": "Krio",
    ]

    /// Every language Google Translate offers as a target.
    public static let all: [TranslationLanguage] = [
        "af", "sq", "am", "ar", "hy", "as", "ay", "az", "bm", "eu", "be", "bn", "bho", "bs", "bg", "ca", "ceb", "ny",
        "zh-CN", "zh-TW", "co", "hr", "cs", "da", "dv", "doi", "nl", "en", "eo", "et", "ee", "tl", "fi", "fr", "fy",
        "gl", "ka", "de", "el", "gn", "gu", "ht", "ha", "haw", "he", "hi", "hmn", "hu", "is", "ig", "ilo", "id", "ga",
        "it", "ja", "jv", "kn", "kk", "km", "rw", "gom", "ko", "kri", "ku", "ckb", "ky", "lo", "la", "lv", "ln", "lt",
        "lg", "lb", "mk", "mai", "mg", "ms", "ml", "mt", "mi", "mr", "mni-Mtei", "lus", "mn", "my", "ne", "no", "or",
        "om", "ps", "fa", "pl", "pt", "pa", "qu", "ro", "ru", "sm", "sa", "gd", "nso", "sr", "st", "sn", "sd", "si",
        "sk", "sl", "so", "es", "su", "sw", "sv", "tg", "ta", "tt", "te", "th", "ti", "ts", "tr", "tk", "ak", "uk",
        "ur", "ug", "uz", "vi", "cy", "xh", "yi", "yo", "zu",
    ].map(TranslationLanguage.init)

    /// Maps what a page or the system says (`en-GB`, `iw`, `zh-Hant`, `pt_BR`)
    /// to the Google code it is translated as, or nil for none.
    public static func matching(_ tag: String) -> TranslationLanguage? {
        let normalized = tag.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return nil }
        let lower = normalized.lowercased()
        if let exact = all.first(where: { $0.code.lowercased() == lower }) { return exact }
        let parts = lower.split(separator: "-").map(String.init)
        let base = parts[0]
        switch base {
        case "zh":
            let traditional = parts.contains { ["hant", "tw", "hk", "mo"].contains($0) }
            return TranslationLanguage(code: traditional ? "zh-TW" : "zh-CN")
        case "iw": return TranslationLanguage(code: "he")
        case "jw": return TranslationLanguage(code: "jv")
        case "nb", "nn": return TranslationLanguage(code: "no")
        case "fil": return TranslationLanguage(code: "tl")
        case "mni": return TranslationLanguage(code: "mni-Mtei")
        default: return all.first { $0.code == base }
        }
    }

    /// The language the person reads: the first preferred language Google can
    /// translate into, else English.
    public static func preferred(from preferredLanguages: [String] = Locale.preferredLanguages) -> TranslationLanguage {
        preferredLanguages.lazy.compactMap(matching).first ?? TranslationLanguage(code: "en")
    }

    /// Whether a page in `pageLanguage` reads as `target` already: same base
    /// language, ignoring region, except that the two Chinese scripts differ.
    public static func isSame(_ pageLanguage: String, as target: TranslationLanguage) -> Bool {
        guard let page = matching(pageLanguage) else { return false }
        return page.code == target.code
    }
}

/// Google Translate, the endpoint Google's own browser extension and
/// website widget use (`client=gtx`): no key, several strings per request,
/// and `format=html` so markup inside a sentence survives translation.
///
/// Not a published API. It is what Chrome-less translation has always used,
/// and it rate-limits heavy use; `TranslatorError.rateLimited` says so
/// rather than leaving half a page untranslated without a word.
public struct GoogleTranslator: Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Keeps a request well inside what the endpoint accepts.
    public static let maxCharactersPerRequest = 4_500
    public static let maxSegmentsPerRequest = 100

    private let fetch: Fetch

    public init(fetch: @escaping Fetch = GoogleTranslator.defaultFetch) {
        self.fetch = fetch
    }

    /// No cookies: a translation request must not carry the person's Google
    /// sign-in, whichever profile asked.
    public static let defaultFetch: Fetch = { request in
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    public struct Translation: Equatable, Sendable {
        public var text: String
        /// What Google took the source to be, when it says.
        public var detectedLanguage: String?
        public init(text: String, detectedLanguage: String? = nil) {
            self.text = text
            self.detectedLanguage = detectedLanguage
        }
    }

    public enum TranslatorError: Error, Equatable, Sendable {
        case rateLimited
        case http(Int)
        /// The response did not have one translation per string sent.
        case unexpectedResponse
    }

    /// Translates `segments` (HTML fragments when `html`) into `target`, in
    /// order. Splits into as many requests as the limits need.
    public func translate(_ segments: [String], to target: TranslationLanguage, from source: String = "auto",
                          html: Bool = true) async throws -> [Translation] {
        var results: [Translation] = []
        for batch in Self.batches(segments) {
            results += try await translateBatch(batch, to: target, from: source, html: html)
        }
        return results
    }

    public func translateBatch(_ segments: [String], to target: TranslationLanguage, from source: String = "auto",
                               html: Bool = true) async throws -> [Translation] {
        guard !segments.isEmpty else { return [] }
        var request = URLRequest(url: Self.endpoint(to: target, from: source, html: html))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formBody(segments).utf8)
        request.httpShouldHandleCookies = false
        let (data, response) = try await fetch(request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw http.statusCode == 429 ? TranslatorError.rateLimited : TranslatorError.http(http.statusCode)
        }
        return try Self.parse(data, expected: segments.count)
    }

    static func endpoint(to target: TranslationLanguage, from source: String, html: Bool) -> URL {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/t")!
        components.queryItems = [
            .init(name: "client", value: "gtx"), .init(name: "sl", value: source),
            .init(name: "tl", value: target.code), .init(name: "format", value: html ? "html" : "text"),
        ]
        return components.url!
    }

    /// `q=…&q=…`, every reserved character escaped, so `&`, `+` and `=` in a
    /// page's text arrive as text.
    public static func formBody(_ segments: [String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return segments.map { "q=" + ($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&")
    }

    /// Groups segments into requests under both limits, keeping order. A
    /// segment longer than the character limit travels alone.
    public static func batches(_ segments: [String], maxCharacters: Int = maxCharactersPerRequest,
                               maxSegments: Int = maxSegmentsPerRequest) -> [[String]] {
        var batches: [[String]] = []
        var current: [String] = []
        var size = 0
        for segment in segments {
            if !current.isEmpty && (size + segment.count > maxCharacters || current.count == maxSegments) {
                batches.append(current)
                current = []
                size = 0
            }
            current.append(segment)
            size += segment.count
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// Each entry is `[translation, detected]`, or a bare string when the
    /// source language was given. One string sent may come back unwrapped.
    public static func parse(_ data: Data, expected: Int) throws -> [Translation] {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { throw TranslatorError.unexpectedResponse }
        if expected == 1, let text = json as? String { return [Translation(text: text)] }
        guard let array = json as? [Any] else { throw TranslatorError.unexpectedResponse }
        if expected == 1, array.count == 2, let text = array[0] as? String, let language = array[1] as? String,
           !(array[0] is [Any]) {
            return [Translation(text: text, detectedLanguage: language)]
        }
        let results: [Translation] = try array.map { entry in
            if let text = entry as? String { return Translation(text: text) }
            if let pair = entry as? [Any], let text = pair.first as? String {
                return Translation(text: text, detectedLanguage: pair.count > 1 ? pair[1] as? String : nil)
            }
            throw TranslatorError.unexpectedResponse
        }
        guard results.count == expected else { throw TranslatorError.unexpectedResponse }
        return results
    }

    /// The language most of the page's text was detected as, weighted by length.
    public static func dominantLanguage(of translations: [Translation], sources: [String]) -> String? {
        var weight: [String: Int] = [:]
        for (translation, source) in zip(translations, sources) {
            if let language = translation.detectedLanguage { weight[language, default: 0] += source.count }
        }
        return weight.max { $0.value < $1.value }?.key
    }
}
