import Foundation
import Testing

/// Window polish Task 1: the built app carries its icon. actool writes `AppIcon.icns` and
/// `CFBundleIconName` for a macOS app whose AppIcon set lists images; an empty set gives neither.
@Suite struct AppIconTests {

    /// The test host is Gitter.app, so `Bundle.main` is the app's own bundle.
    @Test func theHostBundleIsGitter() {
        #expect(Bundle.main.bundleIdentifier == "dev.penzin.Gitter")
    }

    @Test func theBundleNamesItsIcon() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "AppIcon")
    }

    @Test func theBundleCarriesTheCompiledIcon() {
        #expect(Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil)
    }

    /// Control: the same lookup fails for a name the bundle does not have.
    @Test func theLookupFailsForAMissingIcon() {
        withKnownIssue("no such icon is in the bundle") {
            #expect(Bundle.main.url(forResource: "NoSuchIcon", withExtension: "icns") != nil)
        }
        withKnownIssue("no such icon name is in the Info.plist") {
            #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "NoSuchIcon")
        }
    }
}
