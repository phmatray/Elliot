import ElliotStore
import Foundation
import TestSupport
import Testing

/// Where a preference goes, and why the answer is a *path* rather than a
/// convention.
///
/// `UserDefaults.standard` is keyed by bundle identifier, so no `ELLIOT_HOME`
/// can redirect it: a preference kept there bleeds between the operator's real
/// board and every scratch instance a verification pass launches, and the
/// capture that is supposed to prove a feature works stops showing what it
/// claims. Deriving the path from ``StoreLocation/home`` removes that by
/// construction — there is no second code path that could land in the real home,
/// so nobody has to remember anything.
@Suite("Where preferences live")
struct StoreLocationTests {

    /// `TestHome` is the only thing in the process permitted to set
    /// `ELLIOT_HOME`, and its documentation requires touching `root` before any
    /// path is resolved: `StoreLocation` reads the variable on every access, so a
    /// path computed before the `setenv` and again after gives two answers.
    private var home: URL { TestHome.root }

    @Test("The preferences file sits inside ELLIOT_HOME")
    func preferencesLiveInTheConfiguredHome() {
        let home = home
        #expect(StoreLocation.preferencesURL.path.hasPrefix(home.path))
    }

    @Test("It is named preferences.json")
    func itIsNamedPreferencesJSON() {
        _ = home
        #expect(StoreLocation.preferencesURL.lastPathComponent == "preferences.json")
    }

    @Test("It is a sibling of the database, not a child of anything new")
    func itSitsBesideTheDatabase() {
        _ = home
        #expect(
            StoreLocation.preferencesURL.deletingLastPathComponent().path
                == StoreLocation.databaseURL.deletingLastPathComponent().path
        )
    }

    @Test("It follows ELLIOT_HOME, which is the whole reason it is not in UserDefaults")
    func itFollowsTheHome() {
        _ = home
        // Read the property twice around a home that has not moved: what is
        // being pinned is that the answer is *derived* from `home` rather than
        // captured once, because a captured path is how a scratch instance ends
        // up writing into the operator's own preferences.
        #expect(
            StoreLocation.preferencesURL
                == StoreLocation.home.appendingPathComponent("preferences.json")
        )
    }
}
