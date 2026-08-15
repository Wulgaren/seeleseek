import SwiftUI
import SeeleseekCore

@Observable
@MainActor
final class ActivityLog: ActivityLogging {
    static let shared = ActivityLog()

    private(set) var events: [ActivityEvent] = []
    private(set) var hasRecentActivity = false
    private var activityTimer: Timer?

    // Non-observable staging buffer. Log events land here synchronously and
    // are drained into `events` in batches, coalescing observable
    // invalidation so the sidebar console can't drive app-wide frame drops
    // when activity is bursty. See `scheduleFlush` / `flush`.
    private var pendingEvents: [ActivityEvent] = []
    private var flushTask: Task<Void, Never>?
    private static let flushInterval: Duration = .milliseconds(250)

    /// Peer connect/disconnect storms (dozens per second after login/search)
    /// are coalesced into one summary line so the console and its observers
    /// are not woken per peer.
    private var pendingPeerConnects = 0
    private var pendingPeerDisconnects = 0
    private var peerBatchTask: Task<Void, Never>?
    private static let peerBatchInterval: Duration = .seconds(3)

    /// Distributed-search hits (we answered someone else's query) arrive in
    /// a steady drip on a busy relay. Batch into one summary line so the
    /// console is not woken per match — same idea as peer batching.
    private var pendingDistributedSearches = 0
    private var pendingDistributedMatches = 0
    private var distributedBatchTask: Task<Void, Never>?
    private static let distributedBatchInterval: Duration = .seconds(3)

    private let maxEvents = 500

    struct ActivityEvent: Identifiable {
        let id = UUID()
        let timestamp: Date
        let type: EventType
        let title: String
        let detail: String?
        let username: String?
    }

    enum EventType {
        case peerConnected
        case peerDisconnected
        case searchStarted
        case searchResult
        case downloadStarted
        case downloadCompleted
        case uploadStarted
        case uploadCompleted
        case chatMessage
        case error
        case info
        /// Main-thread frame hitch (scroll jank diagnostics).
        case scrollHitch

        var icon: String {
            switch self {
            case .peerConnected: "person.fill.checkmark"
            case .peerDisconnected: "person.fill.xmark"
            case .searchStarted: "magnifyingglass"
            case .searchResult: "doc.text.magnifyingglass"
            case .downloadStarted: "arrow.down.circle"
            case .downloadCompleted: "arrow.down.circle.fill"
            case .uploadStarted: "arrow.up.circle"
            case .uploadCompleted: "arrow.up.circle.fill"
            case .chatMessage: "bubble.left.fill"
            case .error: "exclamationmark.triangle.fill"
            case .info: "info.circle.fill"
            case .scrollHitch: "gauge.with.dots.needle.67percent"
            }
        }

        /// Spoken name for VoiceOver row labels. The icon and its
        /// color are the only visual cues for the event type.
        var spokenName: String {
            switch self {
            case .peerConnected: "Peer connected"
            case .peerDisconnected: "Peer disconnected"
            case .searchStarted: "Search started"
            case .searchResult: "Search result"
            case .downloadStarted: "Download started"
            case .downloadCompleted: "Download completed"
            case .uploadStarted: "Upload started"
            case .uploadCompleted: "Upload completed"
            case .chatMessage: "Chat message"
            case .error: "Error"
            case .info: "Info"
            case .scrollHitch: "Scroll hitch"
            }
        }

        var color: Color {
            switch self {
            case .peerConnected, .downloadCompleted, .uploadCompleted:
                return SeeleColors.success
            case .peerDisconnected:
                return SeeleColors.textTertiary
            case .searchStarted, .searchResult:
                return SeeleColors.info
            case .downloadStarted, .uploadStarted:
                return SeeleColors.accent
            case .chatMessage:
                return SeeleColors.warning
            case .error, .scrollHitch:
                return SeeleColors.error
            case .info:
                return SeeleColors.textSecondary
            }
        }
    }

    private init() {}

    func log(_ type: EventType, title: String, detail: String? = nil, username: String? = nil) {
        let event = ActivityEvent(
            timestamp: Date(),
            type: type,
            title: title,
            detail: detail,
            username: username
        )

        // Stage into the non-observable buffer — no view invalidation yet.
        pendingEvents.append(event)
        scheduleFlush()

        // User-facing notifications are intentionally NOT batched; they
        // have their own dedupe/throttle inside NotificationService.
        NotificationService.shared.handleActivityEvent(type: type, title: title, detail: detail)
    }

    func clear() {
        pendingEvents.removeAll(keepingCapacity: true)
        pendingPeerConnects = 0
        pendingPeerDisconnects = 0
        peerBatchTask?.cancel()
        peerBatchTask = nil
        pendingDistributedSearches = 0
        pendingDistributedMatches = 0
        distributedBatchTask?.cancel()
        distributedBatchTask = nil
        events.removeAll()
        flushTask?.cancel()
        flushTask = nil
    }

    /// Frame hitch for scroll-lag diagnostics. `detail` carries suspect
    /// context (tab, list sizes, transfer activity). Coalesced by
    /// `ScrollHitchMonitor` before it reaches here.
    func logScrollHitch(durationMs: Int, detail: String) {
        log(.scrollHitch, title: "Scroll hitch \(durationMs)ms", detail: detail)
    }

    /// Newest-last text dump of the full console (activity + hitches).
    /// Flushes any pending batch first so Copy all is complete.
    func copyableDump() -> String {
        flushPeerBatch()
        flushDistributedBatch()
        flush()
        let formatter = Self.dumpTimeFormatter
        return events.reversed().map { event in
            var line = "[\(formatter.string(from: event.timestamp))] \(event.type.spokenName): \(event.title)"
            if let detail = event.detail, !detail.isEmpty {
                line += " — \(detail)"
            }
            return line
        }.joined(separator: "\n")
    }

    private static let dumpTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Start a deferred flush of `pendingEvents` into `events`. Subsequent
    /// log calls during the flush window are absorbed into the same batch.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            guard !Task.isCancelled, let self else { return }
            self.flush()
        }
    }

    /// Prepend the pending batch onto `events` in one observable write,
    /// preserving newest-first ordering.
    private func flush() {
        flushTask = nil
        guard !pendingEvents.isEmpty else { return }
        // pendingEvents is append-ordered (oldest first). Reverse so the
        // newest event lands at index 0, matching the pre-batching insert-at-0
        // semantics.
        events.insert(contentsOf: pendingEvents.reversed(), at: 0)
        pendingEvents.removeAll(keepingCapacity: true)
        if events.count > maxEvents {
            events.removeLast(events.count - maxEvents)
        }
        triggerActivity()
    }

    private func triggerActivity() {
        hasRecentActivity = true
        activityTimer?.invalidate()
        activityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.hasRecentActivity = false
            }
        }
    }

    // MARK: - Convenience Methods

    func logPeerConnected(username: String, ip: String) {
        pendingPeerConnects += 1
        schedulePeerBatchFlush()
    }

    func logPeerDisconnected(username: String) {
        pendingPeerDisconnects += 1
        schedulePeerBatchFlush()
    }

    private func schedulePeerBatchFlush() {
        guard peerBatchTask == nil else { return }
        peerBatchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.peerBatchInterval)
            guard !Task.isCancelled, let self else { return }
            self.flushPeerBatch()
        }
    }

    private func flushPeerBatch() {
        peerBatchTask = nil
        let connected = pendingPeerConnects
        let disconnected = pendingPeerDisconnects
        pendingPeerConnects = 0
        pendingPeerDisconnects = 0
        guard connected > 0 || disconnected > 0 else { return }

        var parts: [String] = []
        if connected > 0 {
            parts.append("+\(connected) connected")
        }
        if disconnected > 0 {
            parts.append("−\(disconnected) disconnected")
        }
        let title = "Peers: \(parts.joined(separator: ", "))"
        let type: EventType =
            disconnected == 0 ? .peerConnected
            : connected == 0 ? .peerDisconnected
            : .info
        log(type, title: title)
    }

    func logSearchStarted(query: String) {
        log(.searchStarted, title: "Searching for \"\(query)\"")
    }

    func logSearchResults(query: String, count: Int, user: String) {
        log(.searchResult, title: "\(count) results from \(user)", detail: query, username: user)
    }

    func logDownloadStarted(filename: String, from user: String) {
        log(.downloadStarted, title: "Download started from \(user)", detail: filename, username: user)
    }

    func logDownloadCompleted(filename: String) {
        log(.downloadCompleted, title: "Download completed", detail: filename)
        let displayName = (filename as NSString).lastPathComponent
        VoiceOverAnnouncer.shared.announce("Download complete: \(displayName)")
    }

    func logUploadStarted(filename: String, to user: String) {
        log(.uploadStarted, title: "Upload started to \(user)", detail: filename, username: user)
    }

    func logUploadCompleted(filename: String) {
        log(.uploadCompleted, title: "Upload completed", detail: filename)
    }

    func logChatMessage(from user: String, room: String?) {
        if let room = room {
            log(.chatMessage, title: "Message from \(user)", detail: "in \(room)", username: user)
        } else {
            log(.chatMessage, title: "Private message from \(user)", username: user)
            VoiceOverAnnouncer.shared.announce("Private message from \(user)")
        }
    }

    func logFolderRequestStarted(username: String, folder: String) {
        log(.info, title: "Getting folder contents from \(username)", detail: folder, username: username)
        VoiceOverAnnouncer.shared.announce("Getting folder contents from \(username)")
    }

    func logFolderQueued(count: Int, username: String, folder: String) {
        log(.downloadStarted, title: "Queued \(count) files from \(username)", detail: folder, username: username)
        VoiceOverAnnouncer.shared.announce("Queued \(count) files from \(username)")
    }

    func logFolderRequestFailed(username: String, folder: String, reason: String) {
        log(.error, title: "Folder download from \(username) failed: \(reason)", detail: folder, username: username)
        VoiceOverAnnouncer.shared.announce(reason)
    }

    func logError(_ message: String, detail: String? = nil) {
        log(.error, title: message, detail: detail)
    }

    func logInfo(_ message: String, detail: String? = nil) {
        log(.info, title: message, detail: detail)
    }

    // MARK: - Connection & Server Events

    func logConnectionSuccess(username: String, server: String) {
        log(.info, title: "Connected as \(username)", detail: server)
        VoiceOverAnnouncer.shared.announce("Connected to Soulseek as \(username)")
    }

    func logConnectionFailed(reason: String) {
        log(.error, title: "Login failed", detail: reason)
        VoiceOverAnnouncer.shared.announce("Login failed: \(reason)")
    }

    func logDisconnected(reason: String? = nil) {
        log(.info, title: "Disconnected", detail: reason)
        VoiceOverAnnouncer.shared.announce("Disconnected from the Soulseek server")
    }

    func logRelogged() {
        log(.error, title: "Kicked: another client logged in")
        VoiceOverAnnouncer.shared.announce("Disconnected: another client logged in with your account")
    }

    func logRoomJoined(room: String, userCount: Int) {
        log(.chatMessage, title: "Joined \(room)", detail: "\(userCount) users")
    }

    func logRoomLeft(room: String) {
        log(.chatMessage, title: "Left \(room)")
    }

    func logNATMapping(port: UInt16, success: Bool) {
        if success {
            log(.info, title: "NAT mapped port \(port)")
        } else {
            log(.error, title: "NAT mapping failed", detail: "Port \(port)")
        }
    }

    func logDistributedSearch(query: String, matchCount: Int) {
        pendingDistributedSearches += 1
        pendingDistributedMatches += matchCount
        scheduleDistributedBatchFlush()
    }

    private func scheduleDistributedBatchFlush() {
        guard distributedBatchTask == nil else { return }
        distributedBatchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.distributedBatchInterval)
            guard !Task.isCancelled, let self else { return }
            self.flushDistributedBatch()
        }
    }

    private func flushDistributedBatch() {
        distributedBatchTask = nil
        let searches = pendingDistributedSearches
        let matches = pendingDistributedMatches
        pendingDistributedSearches = 0
        pendingDistributedMatches = 0
        guard searches > 0 else { return }

        let title: String
        if searches == 1 {
            title = "Shared \(matches) match\(matches == 1 ? "" : "es") across 1 search"
        } else {
            title = "Shared \(matches) matches across \(searches) searches"
        }
        log(.searchResult, title: title)
    }
}
