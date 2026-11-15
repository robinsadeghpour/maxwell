// Prints this Mac's "Developer ID Application" signing identity (certificate and private key) as a
// base64 PKCS#12, encrypted with $P12_PASSWORD. macOS asks once to allow the export.
// Used by packaging/ci/set-release-secrets.sh; nothing here is written to disk.
import Foundation
import Security

func fail(_ message: String) -> Never {
  FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
  exit(1)
}

let prefix = ProcessInfo.processInfo.environment["MAXWELL_SIGN_ID"] ?? "Developer ID Application"
guard let password = ProcessInfo.processInfo.environment["P12_PASSWORD"], !password.isEmpty else { fail("Set P12_PASSWORD.") }

var found: CFTypeRef?
let query: [String: Any] = [
  kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll,
  kSecReturnRef as String: true, kSecMatchValidOnDate as String: Date(),
]
guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let identities = found as? [SecIdentity] else {
  fail("No signing identities in the keychain.")
}
let identity = identities.first { id in
  var cert: SecCertificate?
  SecIdentityCopyCertificate(id, &cert)
  return (cert.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "").hasPrefix(prefix)
}
guard let identity else { fail("No valid \"\(prefix)\" identity in the keychain.") }

// The passphrase must outlive SecItemExport: a temporary `password as CFString` is freed first
// under -O, and the export is then encrypted with whatever that memory held.
let passphrase = password as CFString
var params = SecItemImportExportKeyParameters()
params.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
params.passphrase = Unmanaged.passUnretained(passphrase)
var data: CFData?
let status = withExtendedLifetime(passphrase) { SecItemExport(identity, .formatPKCS12, [], &params, &data) }
guard status == errSecSuccess, let data else { fail("Export failed (\(status)). Allow it when macOS asks.") }
print((data as Data).base64EncodedString())
