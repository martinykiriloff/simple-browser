import Foundation

/// What to do with a sign-in the user just submitted.
public enum SaveDecision: Equatable, Sendable {
    /// Already saved exactly like this, or there is nothing worth saving.
    case nothing
    /// A new account for this site: ask "Save password?".
    case offerSave
    /// A known account with a different password: ask "Update password?".
    case offerUpdate(Credential)

    /// - Parameters:
    ///   - currentPassword: what a change-password form had in its "current
    ///     password" field, which says whose password is being changed.
    ///   - existing: the site's saved sign-ins with their passwords.
    public static func decide(username: String, password: String, currentPassword: String = "",
                              existing: [(credential: Credential, password: String)]) -> SaveDecision {
        guard !password.isEmpty else { return .nothing }
        if let same = existing.first(where: { $0.credential.username == username }) {
            return same.password == password ? .nothing : .offerUpdate(same.credential)
        }
        // A change-password form has no username field. If the password is
        // already saved the form was a plain sign-in; if there is exactly one
        // account, the new password can only be that account's.
        if username.isEmpty {
            let owners = currentPassword.isEmpty ? [] : existing.filter { $0.password == currentPassword }
            if owners.count == 1 { return owners[0].password == password ? .nothing : .offerUpdate(owners[0].credential) }
            if existing.contains(where: { $0.password == password }) { return .nothing }
            if existing.count == 1 { return .offerUpdate(existing[0].credential) }
        }
        return .offerSave
    }
}
