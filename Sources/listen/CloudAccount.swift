import Foundation
import CloudKit

/// Whether this build can reach a CloudKit container, and which one.
///
/// The smallest possible probe, and it exists before any sync code does on
/// purpose: Phase 2 of the migration is signing rather than syncing, and its
/// done-when is *a notarized build reporting a usable Production account on a
/// Mac that has never seen it*. Without something that answers that question,
/// the only way to test the signing work is to finish the sync work first.
///
/// It reads the environment out of the embedded provisioning profile rather
/// than assuming, because that is the thing that actually decides, and a build
/// that thinks it is talking to Production while signed for Development fails
/// in a way nothing local reproduces.
enum CloudAccount {
    static let containerID = "iCloud.eu.jacarandalabs.listen"

    /// `Production`, `Development`, or what went wrong finding out.
    ///
    /// From `Contents/embedded.provisionprofile`, which is a CMS blob with a
    /// plist inside it. Parsed by finding the plist rather than by decoding the
    /// signature, because nothing here needs the signature to be valid: if it
    /// were not, the app would not have launched.
    static var environment: String {
        guard let url = Bundle.main.url(forResource: "embedded",
                                        withExtension: "provisionprofile",
                                        subdirectory: nil)
                ?? Bundle.main.bundleURL.appendingPathComponent(
                    "Contents/embedded.provisionprofile") as URL?,
              let data = try? Data(contentsOf: url) else {
            return "unknown (no embedded profile: this build cannot use CloudKit)"
        }
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)) else {
            return "unknown (profile is not in the expected shape)"
        }
        let plist = data[start.lowerBound..<end.upperBound]
        guard let object = try? PropertyListSerialization.propertyList(
                from: plist, options: [], format: nil) as? [String: Any],
              let entitlements = object["Entitlements"] as? [String: Any] else {
            return "unknown (no entitlements in the profile)"
        }
        let key = "com.apple.developer.icloud-container-environment"
        if let one = entitlements[key] as? String { return one }
        if let many = entitlements[key] as? [String] { return many.joined(separator: " or ") }
        return "none (the profile does not mention a container environment)"
    }

    /// The account status, in words rather than as an enum, because every one
    /// of these needs a different thing done about it and a number does not
    /// say which.
    static func status(_ answer: @escaping (String) -> Void) {
        CKContainer(identifier: containerID).accountStatus { status, error in
            if let error {
                answer("cannot tell: \(error.localizedDescription)")
                return
            }
            switch status {
            case .available:
                answer("available")
            case .noAccount:
                answer("no iCloud account is signed in on this Mac")
            case .restricted:
                answer("restricted, most likely by Screen Time or a profile")
            case .couldNotDetermine:
                answer("could not be determined, which usually means no network")
            case .temporarilyUnavailable:
                answer("temporarily unavailable, so try again shortly")
            @unknown default:
                answer("an account status this version does not recognise")
            }
        }
    }
}
