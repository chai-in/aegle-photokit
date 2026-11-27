# Aegle PhotoKit

A Swift package for awaiting one-shot callback requests and grouping assets with matching original-resource digests. Add this directory as a local Swift package dependency and import the `AeglePhotoKit` library. It uses Foundation, requires Swift 6.0 or later, and declares macOS 13 and iOS 16 as minimum Apple deployment targets.

Run the synthetic tests from the package directory with `swift test`.

## Await a request

Wrap a callback API that gives you a cancellation handle. Forward its terminal result to `complete` and return a thread-safe closure that stops or cleans up the underlying request. Call `value()` once per operation. The returned closure runs once when the operation finishes through success, failure, or task cancellation, even if the callback fires before the closure is returned.

```swift
import AeglePhotoKit

func load() async throws -> Int {
    try await PhotoRequestOperation<Int> { complete in
        complete(.success(42))
        return {}
    }.value()
}
```

## Group exact duplicates

Provide lightweight asset records with unique IDs and a `DuplicateDigestReader` that supplies the original byte count and lowercase hexadecimal SHA-256. The caller decides which resources are eligible and computes their digests. The reader can supply an original filename for display.

```swift
import AeglePhotoKit

struct CatalogReader: DuplicateDigestReader {
    let digests: [String: ResourceDigest]

    func digestOriginal(for assetID: String) async throws -> ResourceDigest {
        guard let digest = digests[assetID] else { throw ReadError.unavailable }
        return digest
    }

    enum ReadError: Error { case unavailable }
}

func scan(
    assets: [DuplicateScanAsset],
    digests: [String: ResourceDigest]
) async throws -> DuplicateScanReport {
    try await ExactDuplicateScanner().scan(
        assets: assets,
        reader: CatalogReader(digests: digests)
    )
}
```

The scanner groups records by the pair of SHA-256 and byte count and omits singleton groups. It sorts groups by reclaimable bytes, then by digest, and sorts members by creation date and ID with undated records last. Ineligible assets and ordinary read failures count as skipped. A reader can throw `DuplicateScanError.notAuthorized` to end the scan on loss of access. Cancellation also ends the scan. Pass an `onProgress` closure to receive the start, periodic updates during scanning, and the final counts for a completed scan.

## License

GNU Affero General Public License version 3 only (`AGPL-3.0-only`). See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).
