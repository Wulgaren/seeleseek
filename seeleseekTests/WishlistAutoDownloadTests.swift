import Foundation
import Testing
@testable import seeleseek
@testable import SeeleseekCore

@MainActor
@Suite("Wishlist auto-download")
struct WishlistAutoDownloadTests {
    private func makeSettings(mode: WishlistAutoDownloadMode) -> SettingsState {
        let settings = SettingsState()
        // hasLoaded stays false so toggles do not write UserDefaults.
        settings.wishlistAutoDownloadMode = mode
        settings.wishlistAutoDownloadRequireHighQuality = true
        settings.wishlistAutoDownloadIdleMinutes = 10
        return settings
    }

    private func makeResult(
        username: String,
        filename: String,
        bitrate: UInt32? = 320,
        freeSlots: Bool = true,
        speed: UInt32 = 100
    ) -> SearchResult {
        SearchResult(
            username: username,
            filename: filename,
            size: 100,
            bitrate: bitrate,
            freeSlots: freeSlots,
            uploadSpeed: speed
        )
    }

    @Test("Always mode queues the best new match once")
    func alwaysQueuesBestCopy() {
        let settings = makeSettings(mode: .always)
        let state = WishlistState()
        state.settings = settings
        state.idleTimeProvider = FixedIdleTimeProvider(secondsSinceLastInput: 0)

        let item = WishlistItem(query: "daft punk")
        state.items = [item]

        var queued: [SearchResult] = []
        state.queueDownload = { queued.append($0) }
        state.isTrackOwned = { _ in false }

        let token: UInt32 = 0x8000_0001
        state._setTokenMappingForTest(token: token, itemId: item.id)

        let slow = makeResult(username: "slow", filename: "@@m\\01.flac", speed: 10)
        let fast = makeResult(username: "fast", filename: "@@m\\01.flac", speed: 9_000)
        state.handleSearchResults(token: token, results: [slow, fast])
        #expect(queued.map(\.username) == ["fast"])

        queued.removeAll()
        state.handleSearchResults(token: token, results: [slow, fast])
        #expect(queued.isEmpty)
    }

    @Test("Off mode never queues")
    func offNeverQueues() {
        let settings = makeSettings(mode: .off)
        let state = WishlistState()
        state.settings = settings
        let item = WishlistItem(query: "daft punk")
        state.items = [item]

        var queuedCount = 0
        state.queueDownload = { _ in queuedCount += 1 }

        let token: UInt32 = 0x8000_0002
        state._setTokenMappingForTest(token: token, itemId: item.id)
        state.handleSearchResults(
            token: token,
            results: [makeResult(username: "a", filename: "@@music\\a.flac")]
        )
        #expect(queuedCount == 0)
    }

    @Test("Away mode holds matches until idle, then flushes")
    func awayModeDefersUntilIdle() {
        let settings = makeSettings(mode: .whenAway)
        settings.wishlistAutoDownloadIdleMinutes = 10

        let state = WishlistState()
        state.settings = settings
        state.idleTimeProvider = FixedIdleTimeProvider(secondsSinceLastInput: 30) // 30s < 10m

        let item = WishlistItem(query: "daft punk")
        state.items = [item]

        var queued: [SearchResult] = []
        state.queueDownload = { queued.append($0) }
        state.isTrackOwned = { _ in false }

        let token: UInt32 = 0x8000_0003
        state._setTokenMappingForTest(token: token, itemId: item.id)
        state.handleSearchResults(
            token: token,
            results: [makeResult(username: "a", filename: "@@m\\track.flac")]
        )
        #expect(queued.isEmpty)

        state.idleTimeProvider = FixedIdleTimeProvider(secondsSinceLastInput: 11 * 60)
        state.flushAutoDownloadsIfAllowed()
        #expect(queued.map(\.displayFilename) == ["track.flac"])
    }

    @Test("Skips a track already owned from another peer")
    func skipsOwnedAcrossPeers() {
        let settings = makeSettings(mode: .always)
        let state = WishlistState()
        state.settings = settings
        state.isTrackOwned = { $0 == "track.flac" }

        var queuedCount = 0
        state.queueDownload = { _ in queuedCount += 1 }

        let item = WishlistItem(query: "x")
        state.items = [item]
        let token: UInt32 = 0x8000_0004
        state._setTokenMappingForTest(token: token, itemId: item.id)
        state.handleSearchResults(
            token: token,
            results: [makeResult(username: "other", filename: "@@z\\track.flac")]
        )
        #expect(queuedCount == 0)
    }

    @Test("High-quality filter skips low bitrate when enabled")
    func qualityFilterGatesQueue() {
        let settings = makeSettings(mode: .always)
        settings.wishlistAutoDownloadRequireHighQuality = true

        let state = WishlistState()
        state.settings = settings
        state.isTrackOwned = { _ in false }

        var queued: [SearchResult] = []
        state.queueDownload = { queued.append($0) }

        let item = WishlistItem(query: "x")
        state.items = [item]
        let token: UInt32 = 0x8000_0005
        state._setTokenMappingForTest(token: token, itemId: item.id)
        state.handleSearchResults(
            token: token,
            results: [makeResult(username: "a", filename: "song.mp3", bitrate: 192)]
        )
        #expect(queued.isEmpty)
    }
}
