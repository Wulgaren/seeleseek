import Foundation
import Testing
@testable import SeeleseekCore

@Suite("Wishlist auto-download planner")
struct WishlistAutoDownloadPlannerTests {
    private func result(
        user: String,
        path: String,
        bitrate: UInt32? = nil,
        freeSlots: Bool = true,
        speed: UInt32 = 100,
        queue: UInt32 = 0,
        size: UInt64 = 1_000
    ) -> SearchResult {
        SearchResult(
            username: user,
            filename: path,
            size: size,
            bitrate: bitrate,
            freeSlots: freeSlots,
            uploadSpeed: speed,
            queueLength: queue
        )
    }

    // MARK: - Quality

    @Test("Lossless always meets the floor")
    func losslessPasses() {
        let flac = result(user: "a", path: "@@m\\Album\\01.flac")
        #expect(WishlistAutoDownloadQuality.meetsFloor(flac))
    }

    @Test("MP3 requires 320 kbps")
    func mp3Floor() {
        #expect(WishlistAutoDownloadQuality.meetsFloor(result(user: "a", path: "a.mp3", bitrate: 320)))
        #expect(!WishlistAutoDownloadQuality.meetsFloor(result(user: "a", path: "a.mp3", bitrate: 256)))
        #expect(!WishlistAutoDownloadQuality.meetsFloor(result(user: "a", path: "a.mp3", bitrate: nil)))
    }

    @Test("M4A/AAC requires 256 kbps")
    func aacFloor() {
        #expect(WishlistAutoDownloadQuality.meetsFloor(result(user: "a", path: "a.m4a", bitrate: 256)))
        #expect(WishlistAutoDownloadQuality.meetsFloor(result(user: "a", path: "a.aac", bitrate: 320)))
        #expect(!WishlistAutoDownloadQuality.meetsFloor(result(user: "a", path: "a.m4a", bitrate: 192)))
    }

    @Test("Low-quality and non-audio are rejected")
    func rejectsJunk() {
        #expect(!WishlistAutoDownloadQuality.meetsFloor(result(user: "a", path: "cover.jpg")))
        #expect(!WishlistAutoDownloadQuality.meetsFloor(result(user: "a", path: "a.ogg", bitrate: 320)))
    }

    // MARK: - Selection

    @Test("Picks one best peer per track")
    func bestPeerPerTrack() {
        let slow = result(user: "slow", path: "@@m\\01 Song.flac", freeSlots: true, speed: 50, queue: 0)
        let busy = result(user: "busy", path: "@@m\\01 Song.flac", freeSlots: false, speed: 9_000, queue: 0)
        let fast = result(user: "fast", path: "@@other\\01 Song.flac", freeSlots: true, speed: 5_000, queue: 2)

        let picked = WishlistAutoDownloadPlanner.select(
            from: [slow, busy, fast],
            ownedTrackKeys: [],
            requireQualityFloor: true
        )
        #expect(picked.count == 1)
        #expect(picked[0].username == "fast")
    }

    @Test("Skips tracks already owned from another peer")
    func skipsOwnedTracks() {
        let a = result(user: "a", path: "@@m\\track.flac")
        let picked = WishlistAutoDownloadPlanner.select(
            from: [a],
            ownedTrackKeys: ["track.flac"],
            requireQualityFloor: true
        )
        #expect(picked.isEmpty)
    }

    @Test("Album match picks one peer folder")
    func albumPicksOneFolder() {
        let alice = [
            result(user: "alice", path: "@@m\\Discovery\\01.flac", freeSlots: true, speed: 100),
            result(user: "alice", path: "@@m\\Discovery\\02.flac", freeSlots: true, speed: 100),
        ]
        let bob = [
            result(user: "bob", path: "@@x\\Discovery\\01.flac", freeSlots: true, speed: 8_000),
            result(user: "bob", path: "@@x\\Discovery\\02.flac", freeSlots: true, speed: 8_000),
            result(user: "bob", path: "@@x\\Discovery\\03.flac", freeSlots: true, speed: 8_000),
        ]

        let picked = WishlistAutoDownloadPlanner.select(
            from: alice + bob,
            ownedTrackKeys: [],
            requireQualityFloor: true
        )
        #expect(Set(picked.map(\.username)) == ["bob"])
        #expect(picked.count == 3)
    }

    @Test("Quality floor drops low-bitrate copies before ranking")
    func qualityBeforeRank() {
        let low = result(user: "low", path: "song.mp3", bitrate: 128, freeSlots: true, speed: 99_000)
        let high = result(user: "high", path: "song.mp3", bitrate: 320, freeSlots: false, speed: 10)
        let picked = WishlistAutoDownloadPlanner.select(
            from: [low, high],
            ownedTrackKeys: [],
            requireQualityFloor: true
        )
        #expect(picked.count == 1)
        #expect(picked[0].username == "high")
    }

    @Test("Quality floor can be disabled")
    func qualityOptional() {
        let low = result(user: "low", path: "song.mp3", bitrate: 128)
        let picked = WishlistAutoDownloadPlanner.select(
            from: [low],
            ownedTrackKeys: [],
            requireQualityFloor: false
        )
        #expect(picked.count == 1)
    }
}
