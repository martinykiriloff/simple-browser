import Foundation
import CryptoKit
import UpdateKit

// Release signing, for CI and for a release made by hand.
//
//   UPDATE_SIGNING_KEY=<base64 private key> swift run SignUpdate dist/SimpleBrowser-0.2.0.dmg
//     writes dist/SimpleBrowser-0.2.0.dmg.sig
//   swift run SignUpdate --generate-key
//     prints a new key pair: the private key for the repository secret, the
//     public key for Sources/BrowserApp/Updater.swift

let arguments = CommandLine.arguments.dropFirst()

if arguments.first == "--generate-key" {
    let key = Curve25519.Signing.PrivateKey()
    print("private (repository secret UPDATE_SIGNING_KEY): \(key.rawRepresentation.base64EncodedString())")
    print("public  (Updater.publicKey):                    \(key.publicKey.rawRepresentation.base64EncodedString())")
    exit(0)
}

guard let path = arguments.first else {
    FileHandle.standardError.write(Data("usage: SignUpdate <file> | --generate-key\n".utf8))
    exit(2)
}
guard let privateKey = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"], !privateKey.isEmpty else {
    FileHandle.standardError.write(Data("UPDATE_SIGNING_KEY is not set\n".utf8))
    exit(2)
}
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let signature = try UpdateSignature.sign(data, privateKey: privateKey)
    // Verified against the key's own public half before anything is published.
    let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: privateKey.trimmingCharacters(in: .whitespacesAndNewlines))!)
        .publicKey.rawRepresentation.base64EncodedString()
    try UpdateSignature.verify(data, signature: signature, publicKey: publicKey)
    try Data((signature + "\n").utf8).write(to: URL(fileURLWithPath: path + ".sig"))
    print("signed \(path) → \(path).sig (public key \(publicKey))")
} catch {
    FileHandle.standardError.write(Data("signing failed: \(error)\n".utf8))
    exit(1)
}
