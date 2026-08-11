import Foundation

private final class WebTagShareBundleToken: NSObject {}

enum AppIdentifiers {
    private static let appGroupInfoKey = "WebTagAppGroupIdentifier"

    static var appGroup: String {
        let bundle = Bundle(for: WebTagShareBundleToken.self)
        return bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String ?? ""
    }

    static var keychainAccessGroup: String {
        let bundle = Bundle(for: WebTagShareBundleToken.self)
        return bundle.object(forInfoDictionaryKey: "WebTagKeychainAccessGroup") as? String ?? ""
    }
}
