import Foundation
import Testing
@testable import seeleseek
@testable import SeeleseekCore

@MainActor
@Suite("Wishlist auto-download")
struct WishlistAutoDownloadTests {
    private func makeResult(username: String, filename: String) -> SearchResult {
        SearchResult(username: username, filename: filename, size: 100)
    }

    @Test("Queues only newly seen matches when setting is on")
    func queuesNewMatchesWhenEnabled() {
        let settings = SettingsState()
        // hasLoaded stays false so toggles do not write UserDefaults.
        settings.autoDownloadWishlist = true

        let state = WishlistState()
        state.settings = settings
        let item = WishlistItem(query: "daft punk")
        state.items = [item]

        var queued: [SearchResult] = []
        state.queueDownload = { queued.append($0) }

        let token: UInt32 = 0x8000_0001
        state._setTokenMappingForTest(token: token, itemId: item.id)

        let first = makeResult(username: "a", filename: "@@music\\a.mp3")
        let second = makeResult(username: "b", filename: "@@music\\b.mp3")
        state.handleSearchResults(token: token, results: [first, second])
        #expect(queued.map(\.filename) == ["@@music\\a.mp3", "@@music\\b.mp3"])

        queued.removeAll()
        state.handleSearchResults(token: token, results: [first, second])
        #expect(queued.isEmpty)

        let third = makeResult(username: "c", filename: "@@music\\c.mp3")
        state.handleSearchResults(token: token, results: [first, third])
        #expect(queued.map(\.filename) == ["@@music\\c.mp3"])
    }

    @Test("Does not queue when setting is off")
    func doesNotQueueWhenDisabled() {
        let settings = SettingsState()
        settings.autoDownloadWishlist = false

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
            results: [makeResult(username: "a", filename: "@@music\\a.mp3")]
        )
        #expect(queuedCount == 0)
    }
}
