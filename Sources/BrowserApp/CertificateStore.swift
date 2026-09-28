import AppKit
import CryptoKit
import Security
import BrowserKit

/// Certificate problems waiting on a warning page, and the exceptions made
/// from them. Nothing here is written to disk: an exception lasts until the
/// app quits, as in Safari, so a certificate that was wrong once is
/// questioned again the next day.
@MainActor
final class CertificateStore {
    static let shared = CertificateStore()

    private var exceptions: [String: CertificateExceptions] = [:]
    private var problems: [String: CertificateProblem] = [:]
    private var order: [String] = []

    /// A warning page's token for a problem.
    func add(_ problem: CertificateProblem) -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        problems[token] = problem
        order.append(token)
        if order.count > 40 { problems[order.removeFirst()] = nil }
        return token
    }

    func problem(for token: String?) -> CertificateProblem? { token.flatMap { problems[$0] } }

    func html(for url: URL?) -> String {
        guard let token = WarningPage.token(of: url), let problem = problems[token] else {
            // A warning from before a relaunch: the page is tried again,
            // and warns again if there is still reason to.
            return ReaderPage.redirect(to: WarningPage.original(of: url))
        }
        return WarningPage.html(problem, token: token)
    }

    func exceptions(for profile: String) -> CertificateExceptions { exceptions[profile] ?? CertificateExceptions() }
    func setExceptions(_ value: CertificateExceptions, for profile: String) { exceptions[profile] = value.isEmpty ? nil : value }

    // MARK: - Reading a certificate

    struct Details {
        var fingerprint = ""
        var subject = ""
        var issuer = ""
        var expires: Date?
    }

    /// The certificate the server presented: the first of the chain.
    static func details(of trust: SecTrust?) -> Details {
        guard let trust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return Details() }
        var details = Details()
        details.fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        details.subject = SecCertificateCopySubjectSummary(leaf) as String? ?? ""
        let keys = [kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotAfter] as CFArray
        if let values = SecCertificateCopyValues(leaf, keys, nil) as? [CFString: [CFString: Any]] {
            if let names = values[kSecOIDX509V1IssuerName]?[kSecPropertyKeyValue] as? [[CFString: Any]] {
                let wanted = [kSecOIDCommonName as String, kSecOIDOrganizationName as String]
                let parts = wanted.compactMap { oid in names.first { ($0[kSecPropertyKeyLabel] as? String) == oid }?[kSecPropertyKeyValue] as? String }
                details.issuer = parts.joined(separator: ", ")
            }
            if let after = values[kSecOIDX509V1ValidityNotAfter]?[kSecPropertyKeyValue] as? NSNumber {
                details.expires = Date(timeIntervalSinceReferenceDate: after.doubleValue)
            }
        }
        // A certificate that signed itself.
        if details.issuer.isEmpty, chain.count == 1 { details.issuer = details.subject + " (itself)" }
        return details
    }
}
