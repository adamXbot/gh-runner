import Foundation
import Testing
@testable import RunnerMenu

/// The updater refuses to run rather than run unverified, so the conditions it
/// refuses under are worth pinning down. An app that installs whatever its feed
/// serves is a remote-code-execution channel, and this one manages CI hosts.
struct AppUpdaterTests {
    @Test func soundConfigurationIsAccepted() {
        let reason = AppUpdater.validate(
            publicKey: "8Zq3+examplebase64publickeymaterial=",
            feedURL: "https://adamxbot.github.io/gh-runner/appcast.xml"
        )
        #expect(reason == nil)
    }

    @Test func missingPublicKeyDisablesUpdates() {
        let reason = AppUpdater.validate(
            publicKey: nil,
            feedURL: "https://example.com/appcast.xml"
        )
        #expect(reason?.contains("SUPublicEDKey") == true)
    }

    @Test func emptyPublicKeyDisablesUpdates() {
        // The shipped Info.plist carries an empty key until a keypair exists,
        // which must read as "disabled", not "no key needed".
        let reason = AppUpdater.validate(
            publicKey: "   ",
            feedURL: "https://example.com/appcast.xml"
        )
        #expect(reason?.contains("SUPublicEDKey") == true)
    }

    @Test func placeholderPublicKeyIsRejected() {
        for placeholder in ["REPLACE_ME", "$(SPARKLE_PUBLIC_KEY)"] {
            let reason = AppUpdater.validate(
                publicKey: placeholder,
                feedURL: "https://example.com/appcast.xml"
            )
            #expect(reason?.contains("placeholder") == true, "expected \(placeholder) to be rejected")
        }
    }

    @Test func missingFeedDisablesUpdates() {
        let reason = AppUpdater.validate(publicKey: "validkeymaterial", feedURL: nil)
        #expect(reason?.contains("SUFeedURL") == true)
    }

    @Test func plainHTTPFeedIsRejected() {
        // An appcast fetched over http can be swapped in transit. Signature
        // verification would still catch a tampered payload, but there is no
        // reason to accept the weaker channel.
        let reason = AppUpdater.validate(
            publicKey: "validkeymaterial",
            feedURL: "http://example.com/appcast.xml"
        )
        #expect(reason?.contains("https") == true)
    }

    @Test func shippedInfoPlistIsInternallyConsistent() throws {
        // Guards the real file: if a feed URL is present the key must be too,
        // or a build ships with updates silently disabled.
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RunnerMenuTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Resources/Info.plist")

        let data = try Data(contentsOf: plist)
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
        let dict = try #require(parsed)

        let feed = try #require(dict["SUFeedURL"] as? String)
        #expect(feed.hasPrefix("https://"), "appcast must be served over https")

        // The key is intentionally empty until a keypair exists. Assert the
        // *shape* rather than a value, so this test documents the state instead
        // of breaking the moment the key is filled in.
        let key = dict["SUPublicEDKey"] as? String
        #expect(key != nil, "SUPublicEDKey must be present, even if empty")
        if let key, !key.isEmpty {
            #expect(!key.hasPrefix("REPLACE_"), "placeholder key was committed")
            #expect(!key.contains("$("), "build-time placeholder was committed")
        }
    }
}
