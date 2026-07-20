import Foundation
@testable import PedalsKit
import XCTest

final class RelayMetadataTests: XCTestCase {
    func testHostSnapshotUsesOnlySafeDirectoryFields() throws {
        let metadata = RelayMetadata.hostSnapshot(
            hostName: "Studio",
            sessions: [
                .init(id: 4, alive: true),
                .init(id: 9, alive: false),
            ]
        )
        let text = try metadata.jsonText()
        XCTAssertEqual(try RelayMetadata(jsonText: text), metadata)
        XCTAssertFalse(text.contains("title"))
        XCTAssertFalse(text.contains("cwd"))
        XCTAssertFalse(text.contains("stdout"))
    }

    func testOfflineDirectoryRoundTripsWithReason() throws {
        let metadata = RelayMetadata.terminalDirectory(.init(
            revision: 7,
            online: false,
            hostName: "Studio",
            sessions: [],
            updatedAt: 1_800_000_000,
            reason: .connectionLost
        ))
        XCTAssertEqual(try RelayMetadata(jsonText: metadata.jsonText()), metadata)
    }

    func testChannelStateIsDistinctFromTerminalDirectory() throws {
        let metadata = RelayMetadata.channelState(online: true)
        XCTAssertEqual(try RelayMetadata(jsonText: metadata.jsonText()), metadata)
    }

    func testRejectsDuplicateOrUnorderedDirectoryIDs() {
        let text = #"{"type":"terminal-directory","revision":1,"online":true,"hostName":"Studio","sessions":[{"id":9,"alive":true},{"id":9,"alive":false}],"updatedAt":1}"#
        XCTAssertThrowsError(try RelayMetadata(jsonText: text))
    }

    func testRejectsSessionsInAnOfflineDirectory() {
        let text = #"{"type":"terminal-directory","revision":1,"online":false,"hostName":"Studio","sessions":[{"id":9,"alive":true}],"updatedAt":1,"reason":"connection-lost"}"#
        XCTAssertThrowsError(try RelayMetadata(jsonText: text))
    }
}
