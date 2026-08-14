func appName(for bundleID: String) -> String? {
    guard let bundle = Bundle(identifier: bundleID) else {
        return nil
    }

    return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
}
