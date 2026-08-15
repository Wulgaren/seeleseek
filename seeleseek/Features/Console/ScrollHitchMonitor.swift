import AppKit
import Foundation
import QuartzCore

/// Samples main-thread display frames and logs hitches into `ActivityLog`
/// with a suspect snapshot (which tab, list sizes, transfer load).
///
/// Always on while the main window is live. Coalesces bursts so hitch
/// logging itself does not amplify jank.
@MainActor
final class ScrollHitchMonitor: NSObject {
    static let shared = ScrollHitchMonitor()

    /// Frame gap above this is a hitch (~2 frames at 60 Hz).
    private let hitchThreshold: CFTimeInterval = 1.0 / 30.0
    /// Emit at most one console line per this window; keep the worst hitch.
    private let coalesceInterval: Duration = .milliseconds(500)

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var suspectProvider: (() -> String)?

    private var pendingWorstMs: Int = 0
    private var coalesceTask: Task<Void, Never>?

    private override init() {
        super.init()
    }

    func start(suspects: @escaping () -> String) {
        suspectProvider = suspects
        guard displayLink == nil else { return }
        guard let screen = NSScreen.main else { return }

        // macOS exposes CADisplayLink via NSScreen, not CADisplayLink(target:).
        let link = screen.displayLink(target: self, selector: #selector(onFrame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = 0
        coalesceTask?.cancel()
        coalesceTask = nil
        pendingWorstMs = 0
        suspectProvider = nil
    }

    @objc private func onFrame(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastTimestamp = now }
        guard lastTimestamp > 0 else { return }

        let delta = now - lastTimestamp
        let expected = link.duration > 0 ? link.duration : (1.0 / 60.0)
        let threshold = max(hitchThreshold, expected * 2)
        guard delta >= threshold else { return }

        noteHitch(durationMs: Int((delta * 1000).rounded()))
    }

    private func noteHitch(durationMs: Int) {
        pendingWorstMs = max(pendingWorstMs, durationMs)
        guard coalesceTask == nil else { return }

        coalesceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.coalesceInterval ?? .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            let ms = self.pendingWorstMs
            self.pendingWorstMs = 0
            self.coalesceTask = nil
            guard ms > 0 else { return }
            let detail = self.suspectProvider?() ?? "suspects unavailable"
            ActivityLog.shared.logScrollHitch(durationMs: ms, detail: detail)
        }
    }

    /// Compact one-line snapshot for hitch `detail`.
    static func suspectSnapshot(from appState: AppState) -> String {
        let tab = appState.sidebarSelection?.title ?? "none"
        let searchCount = appState.searchState.filteredResults.count
        let groupedCount = appState.searchState.displayItems.count
        let downloads = appState.transferState.downloads.count
        let uploads = appState.transferState.uploads.count
        let activeDownloads = appState.transferState.activeDownloads.count
        let activeUploads = appState.transferState.activeUploads.count
        // Avoid `filteredFlatTree` here — walking the share tree on the
        // hitch path would add main-thread work during jank.
        let browseTabs = appState.browseState.browses.count
        let browseExpanded = appState.browseState.expandedFolders.count
        let wishlistCount = appState.wishlistState.items.count
        let recent = ActivityLog.shared.events.prefix(3).map(\.type.spokenName).joined(separator: ",")
        let recentPart = recent.isEmpty ? "none" : recent

        return [
            "tab=\(tab)",
            "search=\(searchCount)",
            "grouped=\(groupedCount)",
            "dl=\(downloads)(active:\(activeDownloads))",
            "ul=\(uploads)(active:\(activeUploads))",
            "browseTabs=\(browseTabs)",
            "browseExpanded=\(browseExpanded)",
            "wishlist=\(wishlistCount)",
            "recent=[\(recentPart)]"
        ].joined(separator: " ")
    }
}
