// Copyright (c) 2026 chai-in
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct DuplicateScanAsset: Identifiable, Hashable, Sendable {
    public let id: String
    public let filename: String
    public let creationDate: Date?
    public let isEligible: Bool

    public init(id: String, filename: String, creationDate: Date? = nil, isEligible: Bool = true) {
        self.id = id
        self.filename = filename
        self.creationDate = creationDate
        self.isEligible = isEligible
    }

    fileprivate func replacingFilename(_ filename: String) -> Self {
        Self(id: id, filename: filename, creationDate: creationDate, isEligible: isEligible)
    }
}

public struct ResourceDigest: Hashable, Sendable {
    public let byteCount: Int64
    public let sha256: String

    /// Supply a nonnegative original byte count and the lowercase hexadecimal SHA-256.
    public init(byteCount: Int64, sha256: String) {
        precondition(byteCount >= 0, "The byte count must be nonnegative")
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public enum DuplicateScanError: Error, Equatable, Sendable {
    case notAuthorized
}

public protocol DuplicateDigestReader: Sendable {
    /// Throw `DuplicateScanError.notAuthorized` if access is lost.
    /// Other read errors skip the asset. Cancellation ends the scan.
    func digestOriginal(for assetID: String) async throws -> ResourceDigest

    /// Called only for members of a duplicate group.
    func originalFilename(for assetID: String) -> String?
}

public extension DuplicateDigestReader {
    func originalFilename(for assetID: String) -> String? { nil }
}

public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public let id: ResourceDigest
    public let assets: [DuplicateScanAsset]

    /// Bytes represented by the extra copies, capped at `Int64.max`.
    public var reclaimableByteCount: Int64 {
        let count = exactReclaimableByteCount
        guard count.high == 0 else { return .max }
        return Int64(clamping: count.low)
    }

    fileprivate var exactReclaimableByteCount: (high: Int64, low: UInt64) {
        id.byteCount.multipliedFullWidth(by: Int64(assets.count - 1))
    }
}

public struct DuplicateScanProgress: Equatable, Sendable {
    public let processed: Int
    public let total: Int
    public let skipped: Int
    public let groupsFound: Int

    public var fractionComplete: Double {
        guard total > 0 else { return 0 }
        return Double(processed) / Double(total)
    }
}

public struct DuplicateScanReport: Hashable, Sendable {
    public let groups: [DuplicateGroup]
    public let scannedCount: Int
    public let skippedCount: Int

    public var duplicateCount: Int {
        groups.reduce(0) { $0 + ($1.assets.count - 1) }
    }

    /// Total bytes represented by the extra copies, capped at `Int64.max`.
    public var reclaimableByteCount: Int64 {
        groups.reduce(0) { total, group in
            let (sum, overflow) = total.addingReportingOverflow(group.reclaimableByteCount)
            return overflow ? .max : sum
        }
    }
}

public struct ExactDuplicateScanner: Sendable {
    public init() {}

    /// Scan records with unique asset IDs. Progress starts at zero, updates at
    /// most every 100 ms during the scan, and finishes when all assets are processed.
    public func scan(
        assets: [DuplicateScanAsset],
        reader: some DuplicateDigestReader,
        onProgress: @Sendable (DuplicateScanProgress) async -> Void = { _ in }
    ) async throws -> DuplicateScanReport {
        var firstByDigest: [ResourceDigest: DuplicateScanAsset] = [:]
        var matches: [ResourceDigest: [DuplicateScanAsset]] = [:]
        var lastProgress = ContinuousClock.now
        var skipped = 0

        await onProgress(.init(processed: 0, total: assets.count, skipped: 0, groupsFound: 0))

        for (index, asset) in assets.enumerated() {
            try Task.checkCancellation()

            if asset.isEligible {
                do {
                    let digest = try await reader.digestOriginal(for: asset.id)
                    if matches[digest] != nil {
                        matches[digest, default: []].append(asset)
                    } else if let first = firstByDigest.removeValue(forKey: digest) {
                        matches[digest] = [first, asset]
                    } else {
                        firstByDigest[digest] = asset
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch DuplicateScanError.notAuthorized {
                    throw DuplicateScanError.notAuthorized
                } catch {
                    skipped += 1
                }
            } else {
                skipped += 1
            }

            let processed = index + 1
            if processed == assets.count || lastProgress.duration(to: .now) >= .milliseconds(100) {
                await onProgress(.init(
                    processed: processed,
                    total: assets.count,
                    skipped: skipped,
                    groupsFound: matches.count
                ))
                lastProgress = .now
            }
        }

        try Task.checkCancellation()

        let groups = matches.map { digest, assets in
            DuplicateGroup(
                id: digest,
                assets: assets.map { asset in
                    reader.originalFilename(for: asset.id).map(asset.replacingFilename) ?? asset
                }.sorted(by: assetSort)
            )
        }.sorted { lhs, rhs in
            let leftSize = lhs.exactReclaimableByteCount
            let rightSize = rhs.exactReclaimableByteCount
            if leftSize != rightSize { return leftSize > rightSize }
            if lhs.id.sha256 != rhs.id.sha256 { return lhs.id.sha256 < rhs.id.sha256 }
            return lhs.id.byteCount < rhs.id.byteCount
        }

        return DuplicateScanReport(groups: groups, scannedCount: assets.count - skipped, skippedCount: skipped)
    }

    private func assetSort(_ lhs: DuplicateScanAsset, _ rhs: DuplicateScanAsset) -> Bool {
        switch (lhs.creationDate, rhs.creationDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.id < rhs.id
        }
    }
}
