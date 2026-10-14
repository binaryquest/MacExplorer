import Foundation

/// A virtual location never enters filesystem enumeration or file operations.
public enum BrowserLocation {
    public static let thisMac = URL(string: "explorer://this-mac")!
    public static func isThisMac(_ url: URL) -> Bool { url == thisMac }
    public static func normalized(_ url: URL) -> URL { url.isFileURL ? url.standardizedFileURL : url }
    public static func stored(_ url: URL) -> String { isThisMac(url) ? thisMac.absoluteString : url.path }
    public static func restored(_ value: String) -> URL? {
        if value == thisMac.absoluteString { return thisMac }
        return value.hasPrefix("/") ? URL(fileURLWithPath: value, isDirectory: true) : nil
    }
}
