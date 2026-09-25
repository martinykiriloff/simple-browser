import Foundation

/// Import and export in the CSV every browser's password manager speaks.
///
/// Export writes Chrome's columns (`name,url,username,password,note`). Import
/// goes by the header names, so Chrome, Edge, Brave, Safari (`Title,URL,
/// Username,Password,…`), Firefox and the common password managers all work.
public enum PasswordCSV {
    public struct Row: Equatable, Sendable {
        public var origin: String
        public var username: String
        public var password: String
        public init(origin: String, username: String, password: String) {
            self.origin = origin; self.username = username; self.password = password
        }
    }

    public struct ImportResult: Equatable, Sendable {
        public var rows: [Row] = []
        /// Lines that could not be used: no web address, or no password.
        public var skipped = 0
    }

    public enum ImportError: Error, Equatable, Sendable {
        /// The header has no URL or no password column.
        case unrecognisedHeader
    }

    public static func export(_ rows: [Row]) -> String {
        var lines = ["name,url,username,password,note"]
        for row in rows {
            lines.append([CredentialOrigin.site(of: row.origin), row.origin + "/", row.username, row.password, ""]
                .map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    public static func parse(_ text: String) throws -> ImportResult {
        var records = records(in: text)
        guard !records.isEmpty else { throw ImportError.unrecognisedHeader }
        let header = records.removeFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ names: [String]) -> Int? { header.firstIndex(where: names.contains) }
        guard let urlColumn = column(["url", "login_uri", "website", "web site", "login url"]),
              let passwordColumn = column(["password", "login_password"]) else { throw ImportError.unrecognisedHeader }
        let usernameColumn = column(["username", "login_username", "user name", "login", "email"])

        var result = ImportResult()
        for record in records where !(record.count == 1 && record[0].isEmpty) {
            func field(_ index: Int?) -> String { index.flatMap { record.indices.contains($0) ? record[$0] : nil } ?? "" }
            guard let origin = CredentialOrigin.normalize(field(urlColumn)), !field(passwordColumn).isEmpty else {
                result.skipped += 1
                continue
            }
            result.rows.append(Row(origin: origin, username: field(usernameColumn), password: field(passwordColumn)))
        }
        return result
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { ",\"\r\n".contains($0) }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// RFC 4180: quoted fields may hold commas, line breaks and doubled quotes.
    private static func records(in text: String) -> [[String]] {
        var records: [[String]] = [], record: [String] = [], field = ""
        var quoted = false
        // Unicode scalars, not Characters: "\r\n" is a single Character.
        var scalars = Array(text.unicodeScalars)[...]
        if scalars.first == "\u{FEFF}" { scalars = scalars.dropFirst() }
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            let next = index + 1 < scalars.endIndex ? scalars[index + 1] : nil
            index += 1
            if quoted {
                if scalar == "\"" {
                    if next == "\"" { field.unicodeScalars.append("\""); index += 1 } else { quoted = false }
                } else { field.unicodeScalars.append(scalar) }
            } else if scalar == "\"" && field.isEmpty {
                quoted = true
            } else if scalar == "," {
                record.append(field); field = ""
            } else if scalar == "\n" || scalar == "\r" {
                if scalar == "\r" && next == "\n" { index += 1 }
                record.append(field); field = ""
                records.append(record); record = []
            } else {
                field.unicodeScalars.append(scalar)
            }
        }
        if !field.isEmpty || !record.isEmpty { record.append(field); records.append(record) }
        return records
    }
}
