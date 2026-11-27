// Copyright (c) 2026 chai-in
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
import AeglePhotoKit

@MainActor
final class ExactDuplicateScannerTests: XCTestCase {
    func testGroupsSameDigestAcrossFilenamesAndSortsMembers() async throws {
        let assets = [
            DuplicateScanAsset(id: "d", filename: "undated.jpg"),
            DuplicateScanAsset(id: "c", filename: "c.jpg", creationDate: Date(timeIntervalSince1970: 2)),
            DuplicateScanAsset(id: "b", filename: "b.jpg", creationDate: Date(timeIntervalSince1970: 1)),
            DuplicateScanAsset(id: "unique", filename: "unique.jpg"),
            DuplicateScanAsset(id: "a", filename: "a.jpg", creationDate: Date(timeIntervalSince1970: 1))
        ]
        let shared = digest("a", byteCount: 42)
        let reader = SyntheticReader(
            digests: ["a": shared, "b": shared, "c": shared, "d": shared, "unique": digest("b", byteCount: 27)],
            filenames: ["a": "original.jpg"]
        )

        let report = try await ExactDuplicateScanner().scan(assets: assets, reader: reader)

        XCTAssertEqual(report.groups.map(\.id), [shared])
        let group = try XCTUnwrap(report.groups.first)
        XCTAssertEqual(group.assets.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(group.assets.map(\.filename), ["original.jpg", "b.jpg", "c.jpg", "undated.jpg"])
        XCTAssertEqual(report.duplicateCount, 3)
        XCTAssertEqual(report.reclaimableByteCount, 126)
        XCTAssertEqual(report.scannedCount, 5)
    }

    func testGroupsRequireByteCountAndSortByReclaimableBytesThenDigest() async throws {
        let first = digest("a", byteCount: 50)
        let second = digest("b", byteCount: 100)
        let third = digest("a", byteCount: 10)
        let largest = digest("c", byteCount: 101)
        let reader = SyntheticReader(digests: [
            "a1": first, "a2": first, "a3": first,
            "b1": second, "b2": second,
            "c1": third, "c2": third,
            "d1": largest, "d2": largest
        ])
        let assets = reader.digests.keys.sorted().map { DuplicateScanAsset(id: $0, filename: $0) }

        let report = try await ExactDuplicateScanner().scan(assets: assets, reader: reader)

        XCTAssertEqual(report.groups.map(\.id), [largest, first, second, third])
        XCTAssertEqual(report.groups.map(\.reclaimableByteCount), [101, 100, 100, 10])
    }

    func testLargeByteCountsKeepTheirSortOrderAndCapDisplayedTotals() async throws {
        let smaller = digest("a", byteCount: .max)
        let larger = digest("b", byteCount: .max - 1)
        let reader = SyntheticReader(digests: [
            "a1": smaller, "a2": smaller, "a3": smaller,
            "b1": larger, "b2": larger, "b3": larger, "b4": larger
        ])
        let assets = reader.digests.keys.sorted().map { DuplicateScanAsset(id: $0, filename: $0) }

        let report = try await ExactDuplicateScanner().scan(assets: assets, reader: reader)

        XCTAssertEqual(report.groups.map(\.id), [larger, smaller])
        XCTAssertEqual(report.groups.map(\.reclaimableByteCount), [.max, .max])
        XCTAssertEqual(report.reclaimableByteCount, .max)
    }

    func testSkipsIneligibleAndUnavailableAssetsAndReportsProgress() async throws {
        let assets = [
            DuplicateScanAsset(id: "first", filename: "first.jpg"),
            DuplicateScanAsset(id: "second", filename: "second.jpg"),
            DuplicateScanAsset(id: "unavailable", filename: "cloud.jpg"),
            DuplicateScanAsset(id: "ineligible", filename: "live.heic", isEligible: false)
        ]
        let shared = digest("a", byteCount: 10)
        let reader = SyntheticReader(digests: ["first": shared, "second": shared, "ineligible": shared])
        let progress = ProgressRecorder()

        let report = try await ExactDuplicateScanner().scan(assets: assets, reader: reader) { event in
            await progress.record(event)
        }

        XCTAssertEqual(report.groups.first?.assets.map(\.id), ["first", "second"])
        XCTAssertEqual(report.scannedCount, 2)
        XCTAssertEqual(report.skippedCount, 2)
        let events = await progress.events
        XCTAssertEqual(events.first?.processed, 0)
        XCTAssertEqual(events.first?.total, 4)
        XCTAssertEqual(events.last?.processed, 4)
        XCTAssertEqual(events.last?.skipped, 2)
        XCTAssertEqual(events.last?.groupsFound, 1)
        XCTAssertEqual(events.last?.fractionComplete, 1)
    }

    func testEmptyScanReportsZeroProgressOnce() async throws {
        let progress = ProgressRecorder()

        let report = try await ExactDuplicateScanner().scan(assets: [], reader: SyntheticReader(digests: [:])) { event in
            await progress.record(event)
        }

        XCTAssertTrue(report.groups.isEmpty)
        XCTAssertEqual(report.scannedCount, 0)
        XCTAssertEqual(report.skippedCount, 0)
        let events = await progress.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.fractionComplete, 0)
    }

    func testAuthorizationLossFailsWholeScan() async {
        let assets = [
            DuplicateScanAsset(id: "first", filename: "first.jpg"),
            DuplicateScanAsset(id: "revoked", filename: "revoked.jpg")
        ]
        let reader = SyntheticReader(
            digests: ["first": digest("a", byteCount: 10)],
            failures: ["revoked": DuplicateScanError.notAuthorized]
        )

        do {
            _ = try await ExactDuplicateScanner().scan(assets: assets, reader: reader)
            XCTFail("Expected authorization failure")
        } catch {
            XCTAssertEqual(error as? DuplicateScanError, .notAuthorized)
        }
    }

    func testReaderCancellationFailsWholeScan() async {
        let assets = [DuplicateScanAsset(id: "interrupted", filename: "example.jpg")]
        let reader = SyntheticReader(digests: [:], failures: ["interrupted": CancellationError()])

        do {
            _ = try await ExactDuplicateScanner().scan(assets: assets, reader: reader)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func digest(_ key: String, byteCount: Int64) -> ResourceDigest {
        ResourceDigest(byteCount: byteCount, sha256: String(repeating: key, count: 64))
    }
}

private struct SyntheticReader: DuplicateDigestReader {
    let digests: [String: ResourceDigest]
    var filenames: [String: String] = [:]
    var failures: [String: any Error] = [:]

    func digestOriginal(for assetID: String) async throws -> ResourceDigest {
        if let error = failures[assetID] { throw error }
        guard let digest = digests[assetID] else { throw SyntheticError.unavailable }
        return digest
    }

    func originalFilename(for assetID: String) -> String? {
        filenames[assetID]
    }
}

private enum SyntheticError: Error {
    case unavailable
}

private actor ProgressRecorder {
    private(set) var events: [DuplicateScanProgress] = []

    func record(_ event: DuplicateScanProgress) {
        events.append(event)
    }
}
