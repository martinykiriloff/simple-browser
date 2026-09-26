import Foundation
import TranslateKit

// Unit checks for TranslateKit: `swift run TranslateKitChecks`.
// `--live` also sends two strings to Google Translate and checks the answer.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passed = 0

func check(_ name: String, _ ok: Bool, _ detail: Any? = nil) {
    if ok { passed += 1 } else { failures += 1; print("✘ \(name)" + (detail.map { ": \($0)" } ?? "")) }
}

// MARK: Languages

check("over a hundred target languages", TranslationLanguage.all.count > 130, TranslationLanguage.all.count)
check("codes are unique", Set(TranslationLanguage.all.map(\.code)).count == TranslationLanguage.all.count)
check("every language has a name", TranslationLanguage.all.allSatisfy { !$0.name.isEmpty })
check("a region is ignored", TranslationLanguage.matching("en-GB")?.code == "en")
check("underscores work too", TranslationLanguage.matching("pt_BR")?.code == "pt")
check("traditional Chinese by script", TranslationLanguage.matching("zh-Hant-TW")?.code == "zh-TW")
check("traditional Chinese by region", TranslationLanguage.matching("zh-HK")?.code == "zh-TW")
check("simplified Chinese is the default", TranslationLanguage.matching("zh")?.code == "zh-CN")
check("Google's old Hebrew code", TranslationLanguage.matching("iw")?.code == "he")
check("Norwegian Bokmål", TranslationLanguage.matching("nb-NO")?.code == "no")
check("an unknown tag is nil", TranslationLanguage.matching("xx-unknown") == nil)
check("an empty tag is nil", TranslationLanguage.matching(" ") == nil)
check("the first translatable preferred language is the target", TranslationLanguage.preferred(from: ["xx", "de-CH", "en"]).code == "de")
check("with nothing translatable, English", TranslationLanguage.preferred(from: ["xx"]).code == "en")
check("en-US reads as English", TranslationLanguage.isSame("en-US", as: .init(code: "en")))
check("Chinese scripts differ", !TranslationLanguage.isSame("zh-TW", as: .init(code: "zh-CN")))

// MARK: Requests

check("the form body escapes & + = and spaces", GoogleTranslator.formBody(["a&b+c=d e", "é"]) == "q=a%26b%2Bc%3Dd%20e&q=%C3%A9")
let long = String(repeating: "x", count: 5_000)
let batches = GoogleTranslator.batches(["a", "b", long, "c"], maxCharacters: 4_500, maxSegments: 100)
check("batches keep order and put an oversized segment alone", batches == [["a", "b"], [long], ["c"]], batches.map(\.count))
check("batches respect the segment count", GoogleTranslator.batches(Array(repeating: "a", count: 250)).map(\.count) == [100, 100, 50])
check("no segments, no batches", GoogleTranslator.batches([]).isEmpty)

// MARK: Responses

do {
    let pairs = try GoogleTranslator.parse(Data(#"[["Bonjour <b>le monde</b>","en"],["Bonjour","en"]]"#.utf8), expected: 2)
    check("pairs parse with the detected language", pairs == [.init(text: "Bonjour <b>le monde</b>", detectedLanguage: "en"), .init(text: "Bonjour", detectedLanguage: "en")])
    let one = try GoogleTranslator.parse(Data(#"[["Bonjour le monde","en"]]"#.utf8), expected: 1)
    check("a single pair parses", one == [.init(text: "Bonjour le monde", detectedLanguage: "en")])
    let flat = try GoogleTranslator.parse(Data(#"["Bonjour","en"]"#.utf8), expected: 1)
    check("a single unwrapped pair parses", flat == [.init(text: "Bonjour", detectedLanguage: "en")])
    let bare = try GoogleTranslator.parse(Data(#"["Hallo","Welt"]"#.utf8), expected: 2)
    check("bare strings parse, when the source was given", bare.map(\.text) == ["Hallo", "Welt"])
    let string = try GoogleTranslator.parse(Data(#""Hallo""#.utf8), expected: 1)
    check("a bare string for one segment parses", string.map(\.text) == ["Hallo"])
} catch {
    check("responses parse", false, error)
}
do {
    _ = try GoogleTranslator.parse(Data(#"[["a","en"]]"#.utf8), expected: 2)
    check("a short response is an error", false)
} catch { check("a short response is an error", error as? GoogleTranslator.TranslatorError == .unexpectedResponse) }
do {
    _ = try GoogleTranslator.parse(Data("<html>".utf8), expected: 1)
    check("an HTML error page is an error", false)
} catch { check("an HTML error page is an error", error as? GoogleTranslator.TranslatorError == .unexpectedResponse) }

check("the dominant language is weighted by length",
      GoogleTranslator.dominantLanguage(of: [.init(text: "", detectedLanguage: "fr"), .init(text: "", detectedLanguage: "en")],
                                        sources: ["a long French paragraph", "OK"]) == "fr")

// MARK: The client

final class Log: @unchecked Sendable { var requests: [URLRequest] = [] }
let log = Log()
let stub = GoogleTranslator { request in
    log.requests.append(request)
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    let count = body.components(separatedBy: "q=").count - 1
    let json = "[" + Array(repeating: #"["T","fr"]"#, count: count).joined(separator: ",") + "]"
    return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}
do {
    let result = try await stub.translate(Array(repeating: "hello", count: 150), to: .init(code: "de"))
    check("150 segments come back as 150 translations", result.count == 150)
    check("in two requests", log.requests.count == 2)
    let url = log.requests.first?.url?.absoluteString ?? ""
    check("the request names the target and asks for HTML", url.contains("tl=de") && url.contains("format=html") && url.contains("sl=auto"), url)
    check("the text is in the POST body, not the URL", !url.contains("hello") && log.requests.first?.httpMethod == "POST")
    check("no cookies are sent", log.requests.allSatisfy { !$0.httpShouldHandleCookies })
} catch {
    check("the stubbed client works", false, error)
}
let limited = GoogleTranslator { request in
    (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
}
do {
    _ = try await limited.translate(["x"], to: .init(code: "de"))
    check("429 is rate limiting", false)
} catch { check("429 is rate limiting", error as? GoogleTranslator.TranslatorError == .rateLimited) }

// MARK: Live (opt-in)

if CommandLine.arguments.contains("--live") {
    do {
        let result = try await GoogleTranslator().translate(["Hello <a i=0>world</a>", "Good morning"], to: .init(code: "fr"))
        check("live: two translations", result.count == 2, result)
        check("live: markup survives", result.first?.text.contains("<a i=\"0\">") == true || result.first?.text.contains("<a i=0>") == true, result.first?.text as Any)
        check("live: English was detected", result.first?.detectedLanguage == "en", result.first?.detectedLanguage as Any)
        print("  live: \(result.map(\.text))")
    } catch {
        check("live: Google answered", false, error)
    }
}

print(failures == 0 ? "✔ all \(passed) TranslateKit checks passed" : "✘ \(failures) of \(passed + failures) checks failed")
exit(failures == 0 ? 0 : 1)
