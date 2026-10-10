import Foundation

/// Quality floor for wishlist auto-download: lossless, MP3 ≥ 320 kbps,
/// or AAC/M4A ≥ 256 kbps. Unknown/missing bitrate on lossy formats fails.
public enum WishlistAutoDownloadQuality: Sendable {
    public static let mp3MinimumBitrate: UInt32 = 320
    public static let aacMinimumBitrate: UInt32 = 256

    public static func meetsFloor(_ result: SearchResult) -> Bool {
        let ext = result.fileExtension
        guard FileTypes.isAudio(ext) else { return false }

        if FileTypes.isLossless(ext) {
            return true
        }

        switch ext {
        case "mp3":
            guard let bitrate = result.bitrate else { return false }
            return bitrate >= mp3MinimumBitrate
        case "m4a", "aac":
            guard let bitrate = result.bitrate else { return false }
            return bitrate >= aacMinimumBitrate
        default:
            return false
        }
    }
}

/// Picks one best copy per track (and one peer folder per album) for
/// wishlist auto-download. Pure so tests don't need the network stack.
public enum WishlistAutoDownloadPlanner: Sendable {
    /// Normalized leaf filename used to detect the same track across peers.
    public static func trackKey(for result: SearchResult) -> String {
        result.displayFilename.lowercased()
    }

    /// Album / folder leaf used to pick one peer's folder for a multi-file hit.
    public static func albumKey(for result: SearchResult) -> String? {
        let leaf = result.folderPath.split(separator: "\\").last.map(String.init) ?? ""
        let trimmed = leaf.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    /// Whether `a` should beat `b` after both already meet the quality floor.
    /// Order: free slot, upload speed, shorter queue, then higher bitrate / size.
    public static func isBetterCandidate(_ a: SearchResult, than b: SearchResult) -> Bool {
        if a.freeSlots != b.freeSlots { return a.freeSlots && !b.freeSlots }
        if a.uploadSpeed != b.uploadSpeed { return a.uploadSpeed > b.uploadSpeed }
        if a.queueLength != b.queueLength { return a.queueLength < b.queueLength }
        let aBitrate = a.bitrate ?? 0
        let bBitrate = b.bitrate ?? 0
        if aBitrate != bBitrate { return aBitrate > bBitrate }
        if a.size != b.size { return a.size > b.size }
        return false
    }

    /// Select files to queue from a batch of wishlist hits.
    ///
    /// - Multi-file peer folders (≥2 audio files after filtering) compete as
    ///   albums: one peer folder wins per album leaf name; all of its
    ///   remaining tracks are queued together.
    /// - Everything else competes per track leaf name; one peer wins.
    /// - `ownedTrackKeys` skips tracks already queued / in progress / completed
    ///   from any peer (lowercase leaf names).
    public static func select(
        from results: [SearchResult],
        ownedTrackKeys: Set<String>,
        requireQualityFloor: Bool
    ) -> [SearchResult] {
        let eligible = results.filter { result in
            guard FileTypes.isAudio(result.fileExtension) else { return false }
            if requireQualityFloor {
                return WishlistAutoDownloadQuality.meetsFloor(result)
            }
            return true
        }
        guard !eligible.isEmpty else { return [] }

        var owned = ownedTrackKeys
        var selected: [SearchResult] = []

        // Peer-folder buckets in encounter order.
        var folderOrder: [String] = []
        var folderBuckets: [String: [SearchResult]] = [:]
        for result in eligible {
            let key = "\(result.username)\0\(result.folderPath)"
            if folderBuckets[key] == nil {
                folderOrder.append(key)
            }
            folderBuckets[key, default: []].append(result)
        }

        let albumFolders = folderOrder.compactMap { key -> (album: String, folderKey: String, files: [SearchResult])? in
            guard let files = folderBuckets[key], files.count >= 2 else { return nil }
            guard let album = albumKey(for: files[0]) else { return nil }
            return (album, key, files)
        }

        var claimedFolderKeys = Set<String>()
        var albums: [String: [(folderKey: String, files: [SearchResult])]] = [:]
        for entry in albumFolders {
            albums[entry.album, default: []].append((entry.folderKey, entry.files))
        }

        for (_, offerings) in albums {
            guard let winner = bestFolder(offerings) else { continue }
            claimedFolderKeys.insert(winner.folderKey)
            for file in winner.files.sorted(by: {
                $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            }) {
                let track = trackKey(for: file)
                guard !owned.contains(track) else { continue }
                selected.append(file)
                owned.insert(track)
            }
        }

        // Singles and files from non-album folders: best peer per track.
        var bestByTrack: [String: SearchResult] = [:]
        for result in eligible {
            let folderKey = "\(result.username)\0\(result.folderPath)"
            if claimedFolderKeys.contains(folderKey) { continue }
            let track = trackKey(for: result)
            guard !owned.contains(track) else { continue }
            if let existing = bestByTrack[track] {
                if isBetterCandidate(result, than: existing) {
                    bestByTrack[track] = result
                }
            } else {
                bestByTrack[track] = result
            }
        }

        for track in bestByTrack.keys.sorted() {
            guard let result = bestByTrack[track] else { continue }
            selected.append(result)
            owned.insert(track)
        }

        return selected
    }

    private static func bestFolder(
        _ offerings: [(folderKey: String, files: [SearchResult])]
    ) -> (folderKey: String, files: [SearchResult])? {
        guard var best = offerings.first else { return nil }
        for offering in offerings.dropFirst() {
            if isBetterFolder(offering.files, than: best.files) {
                best = offering
            }
        }
        return best
    }

    /// Folder rank uses the strongest file in each folder as the peer signal.
    private static func isBetterFolder(_ a: [SearchResult], than b: [SearchResult]) -> Bool {
        guard let bestA = a.max(by: { isBetterCandidate($1, than: $0) }) else { return false }
        guard let bestB = b.max(by: { isBetterCandidate($1, than: $0) }) else { return true }
        if isBetterCandidate(bestA, than: bestB) { return true }
        if isBetterCandidate(bestB, than: bestA) { return false }
        // Tie-break: more complete folder wins.
        return a.count > b.count
    }
}
