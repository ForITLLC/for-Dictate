import Foundation
import XCTest
@testable import VoiceInk

final class CompanyDictionaryCallbackRouteTests: XCTestCase {
    func testEachBundleConsumesItsOwnSuccessAndErrorCallbacks() throws {
        for bundle in ["io.forit.dictate", "io.forit.dictate.dev"] {
            for query in ["code=synthetic&state=synthetic", "error=access_denied"] {
                let url = try XCTUnwrap(URL(string: "\(bundle)://oauth/callback?\(query)"))
                XCTAssertTrue(CompanyDictionaryCallbackRoute.matches(url, bundleID: bundle))
            }
        }
    }

    func testDebugAndReleaseCannotConsumeEachOthersCallback() throws {
        for (owner, other) in [("io.forit.dictate", "io.forit.dictate.dev"),
                               ("io.forit.dictate.dev", "io.forit.dictate")] {
            let url = try XCTUnwrap(URL(string: "\(other)://oauth/callback?code=synthetic"))
            XCTAssertFalse(CompanyDictionaryCallbackRoute.matches(url, bundleID: owner))
        }
    }

    func testRejectsWrongAuthorityPathAndCredentialBearingURLs() throws {
        for address in ["io.forit.dictate://other/callback", "io.forit.dictate://oauth/Callback",
                        "io.forit.dictate://oauth/callback/", "io.forit.dictate://oauth:443/callback",
                        "io.forit.dictate://user@oauth/callback", "io.forit.dictate://user:password@oauth/callback",
                        "https://oauth/callback", "io.forit.dictate:/oauth/callback"] {
            let url = try XCTUnwrap(URL(string: address))
            XCTAssertFalse(CompanyDictionaryCallbackRoute.matches(url, bundleID: "io.forit.dictate"), address)
        }
    }

    func testMediaImportsRemainOutsideTheCallbackRoute() throws {
        for address in ["file:///synthetic/recording.m4a", "file:///synthetic/callback.wav",
                        "https://example.invalid/audio.mp3"] {
            let url = try XCTUnwrap(URL(string: address))
            XCTAssertFalse(CompanyDictionaryCallbackRoute.matches(url, bundleID: "io.forit.dictate"))
        }
    }
}
