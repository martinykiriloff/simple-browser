import Foundation

/// HTTP Archive 1.2, the interchange format Chrome's Network panel exports.
/// Fields a source could not observe are left at the spec's "unknown" values
/// (-1, empty) rather than invented.
public enum HARExporter {

    public static func export(_ requests: [NetworkRequest], pageURL: URL?, pageTitle: String?, creatorVersion: String = "0.1") throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let pageID = "page_1"
        let pageStart = requests.map(\.startedAt).min() ?? .now

        let entries: [[String: Any]] = requests.map { r in
            let timing = r.timing
            func phase(_ start: Double, _ end: Double) -> Double {
                (start > 0 && end > 0 && end >= start) ? end - start : -1
            }
            var timings: [String: Any] = ["blocked": -1, "dns": -1, "connect": -1, "ssl": -1,
                                          "send": 0, "wait": -1, "receive": -1]
            if let t = timing {
                timings["dns"] = phase(t.domainLookupStart, t.domainLookupEnd)
                timings["connect"] = phase(t.connectStart, t.connectEnd)
                timings["ssl"] = phase(t.secureConnectionStart, t.connectEnd)
                timings["wait"] = phase(t.requestStart, t.responseStart)
                timings["receive"] = phase(t.responseStart, t.responseEnd)
                timings["blocked"] = phase(t.fetchStart, max(t.domainLookupStart, t.connectStart, t.requestStart))
            }

            var response: [String: Any] = [
                "status": r.statusCode ?? 0,
                "statusText": "",
                "httpVersion": r.protocolName ?? "",
                "cookies": [],
                "headers": headerList(r.responseHeaders),
                "redirectURL": "",
                "headersSize": -1,
                "bodySize": r.bodySize ?? -1,
                "content": [
                    "size": r.bodySize ?? -1,
                    "mimeType": r.mimeType ?? "",
                    "text": r.responseBody ?? "",
                ] as [String: Any],
            ]
            if r.transferSize != nil { response["_transferSize"] = r.transferSize! }

            var request: [String: Any] = [
                "method": r.method ?? "GET",
                "url": r.url.absoluteString,
                "httpVersion": r.protocolName ?? "",
                "cookies": [],
                "headers": headerList(r.requestHeaders),
                "queryString": queryList(r.url),
                "headersSize": -1,
                "bodySize": r.requestBody.map { Int64($0.utf8.count) } ?? -1,
            ]
            if let body = r.requestBody {
                request["postData"] = [
                    "mimeType": r.requestHeaders.first(where: { $0.key.lowercased() == "content-type" })?.value ?? "",
                    "text": body,
                ] as [String: Any]
            }

            var entry: [String: Any] = [
                "pageref": pageID,
                "startedDateTime": formatter.string(from: r.startedAt),
                "time": (r.duration ?? 0) * 1000,
                "request": request,
                "response": response,
                "cache": [:],
                "timings": timings,
                "_resourceType": r.resourceType,
                "_sources": r.sources.map(\.rawValue),
            ]
            if let initiator = r.initiator { entry["_initiator"] = ["type": initiator] }
            if let failure = r.failure { entry["_error"] = failure }
            return entry
        }

        let log: [String: Any] = [
            "log": [
                "version": "1.2",
                "creator": ["name": "SimpleBrowser", "version": creatorVersion],
                "pages": [[
                    "startedDateTime": formatter.string(from: pageStart),
                    "id": pageID,
                    "title": pageTitle ?? pageURL?.absoluteString ?? "",
                    "pageTimings": ["onContentLoad": -1, "onLoad": -1],
                ] as [String: Any]],
                "entries": entries,
            ] as [String: Any],
        ]
        return try JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func headerList(_ headers: [String: String]) -> [[String: String]] {
        headers.sorted { $0.key < $1.key }.map { ["name": $0.key, "value": $0.value] }
    }

    private static func queryList(_ url: URL) -> [[String: String]] {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ["name": $0.name, "value": $0.value ?? ""] }
    }
}
