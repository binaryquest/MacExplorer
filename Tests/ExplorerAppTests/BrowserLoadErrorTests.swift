import Foundation
import Testing
@testable import ExplorerApp

struct BrowserLoadErrorTests {
    @Test(arguments: [EPERM, EACCES, ENOTDIR])
    func googleDriveShortcutOffersRecoveryForWrappedReadErrors(code: Int32) {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        ])
        #expect(BrowserLoadError(folderError: error, isGoogleDriveShortcut: true) == .googleDriveAccess)
        #expect(BrowserLoadError(folderError: error, isGoogleDriveShortcut: false) == .other(error.localizedDescription))
    }

    @Test func googleDriveShortcutHandlesDirectPermissionAndOpaqueReadErrors() {
        for code in [NSFileReadNoPermissionError, NSFileReadUnknownError] {
            let error = NSError(domain: NSCocoaErrorDomain, code: code)
            #expect(BrowserLoadError(folderError: error, isGoogleDriveShortcut: true) == .googleDriveAccess)
        }
    }

    @Test func googleDriveShortcutKeepsMissingFolderError() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        #expect(BrowserLoadError(folderError: error, isGoogleDriveShortcut: true) == .other(error.localizedDescription))
    }
}
