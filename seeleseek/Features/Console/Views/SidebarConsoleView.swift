import SwiftUI
import AppKit
import SeeleseekCore

struct SidebarConsoleView: View {
    @State private var activityLog = ActivityLog.shared
    @State private var isExpanded = false
    /// Snapshot taken when collapsing (or on first appear). Collapsed UI
    /// must not read `activityLog.events` so Observation cannot invalidate
    /// the sidebar while the console is closed.
    @State private var frozenPeek: ActivityLog.ActivityEvent?
    @State private var frozenCount = 0
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(SeeleColors.divider)

            if isExpanded {
                expandedView
            } else {
                collapsedView
            }
        }
        .background(SeeleColors.surfaceSecondary)
        .onAppear {
            captureFreezeFrame()
        }
    }

    // MARK: - Collapsed

    private var collapsedView: some View {
        VStack(spacing: 0) {
            header
            if let latest = frozenPeek {
                peekLine(latest)
            }
        }
    }

    // MARK: - Expanded

    private var expandedView: some View {
        VStack(spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(activityLog.events.reversed()) { event in
                            consoleRow(event)
                                .id(event.id)
                        }
                    }
                    .padding(.vertical, SeeleSpacing.xxs)
                }
                .onChange(of: activityLog.events.count) { _, _ in
                    if let latest = activityLog.events.first {
                        // No animation — animated scrollTo during hitch
                        // logging would pollute the signal we're measuring.
                        proxy.scrollTo(latest.id, anchor: .bottom)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }

    // MARK: - Header

    // The clear button is a sibling of the toggle button. A button
    // nested inside another button's label is not reachable with
    // VoiceOver.
    private var header: some View {
        HStack(spacing: SeeleSpacing.xs) {
            Button {
                toggleExpanded()
            } label: {
                HStack(spacing: SeeleSpacing.xs) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(SeeleColors.textTertiary)
                        .accessibilityHidden(true)

                    Text("Console")
                        .font(SeeleTypography.caption)
                        .foregroundStyle(SeeleColors.textSecondary)

                    let count = isExpanded ? activityLog.events.count : frozenCount
                    if count > 0 {
                        Text("\(count)")
                            .font(SeeleTypography.monoXSmall)
                            .foregroundStyle(SeeleColors.textTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(SeeleColors.surfaceElevated, in: Capsule())
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Console, \(isExpanded ? activityLog.events.count : frozenCount) events")
            .accessibilityValue(isExpanded ? "expanded" : "collapsed")

            if isExpanded {
                Button {
                    copyAll()
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(SeeleColors.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(didCopy ? "Copied" : "Copy all")
                .help("Copy all console lines")

                Button {
                    activityLog.clear()
                    captureFreezeFrame()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                        .foregroundStyle(SeeleColors.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear console")
            }

            Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                .font(.system(size: 8))
                .foregroundStyle(SeeleColors.textTertiary)
                .accessibilityHidden(true)
                // The chevron sits outside the toggle button. Keep
                // the old click-to-toggle behavior for mouse users.
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleExpanded()
                }
        }
        .padding(.horizontal, SeeleSpacing.lg)
        .padding(.vertical, SeeleSpacing.sm)
    }

    // MARK: - Actions

    private func toggleExpanded() {
        if isExpanded {
            // About to collapse — freeze the visible peek/count.
            captureFreezeFrame()
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded.toggle()
        }
        didCopy = false
    }

    private func captureFreezeFrame() {
        frozenPeek = activityLog.events.first
        frozenCount = activityLog.events.count
    }

    private func copyAll() {
        let dump = activityLog.copyableDump()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dump, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }

    // MARK: - Rows

    private func peekLine(_ event: ActivityLog.ActivityEvent) -> some View {
        HStack(spacing: SeeleSpacing.xs) {
            Image(systemName: event.type.icon)
                .font(.system(size: 7))
                .foregroundStyle(event.type.color)

            Text(event.title)
                .font(SeeleTypography.monoXSmall)
                .foregroundStyle(SeeleColors.textTertiary)
                .lineLimit(1)

            Spacer()

            Text(formatTime(event.timestamp))
                .font(SeeleTypography.monoXSmall)
                .foregroundStyle(SeeleColors.textTertiary.opacity(0.6))
        }
        .padding(.horizontal, SeeleSpacing.lg)
        .padding(.bottom, SeeleSpacing.sm)
        .opacity(0.7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel(event))
        .accessibilityAddTraits(.isStaticText)
    }

    private func consoleRow(_ event: ActivityLog.ActivityEvent) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: SeeleSpacing.xs) {
                Image(systemName: event.type.icon)
                    .font(.system(size: 8))
                    .foregroundStyle(event.type.color)
                    .frame(width: 12)

                Text(formatTime(event.timestamp))
                    .font(SeeleTypography.monoXSmall)
                    .foregroundStyle(SeeleColors.textTertiary)

                Text(event.title)
                    .font(SeeleTypography.monoSmall)
                    .foregroundStyle(SeeleColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Hitch suspects are the reason this console exists during
            // lag hunts — show them without requiring Copy all.
            if event.type == .scrollHitch, let detail = event.detail {
                Text(detail)
                    .font(SeeleTypography.monoXSmall)
                    .foregroundStyle(SeeleColors.textTertiary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12 + SeeleSpacing.xs)
            }
        }
        .padding(.horizontal, SeeleSpacing.lg)
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel(event))
        .accessibilityAddTraits(.isStaticText)
    }

    private func rowAccessibilityLabel(_ event: ActivityLog.ActivityEvent) -> String {
        var label = "\(event.type.spokenName), \(formatTime(event.timestamp)), \(event.title)"
        if event.type == .scrollHitch, let detail = event.detail {
            label += ", \(detail)"
        }
        return label
    }

    private func formatTime(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - Previews
//
// The console reads from `ActivityLog.shared`, a @MainActor singleton, which
// starts empty. Each preview clears the log and seeds a representative event
// mix, then renders at the sidebar's real width (220pt). Expand/collapse is
// interactive in the Xcode canvas — click the chevron to switch states.

private func seedConsolePreview(_ events: () -> Void) {
    let log = ActivityLog.shared
    log.clear()
    events()
}

#Preview("Empty") {
    SidebarConsoleView()
        .frame(width: 220, height: 80)
        .background(SeeleColors.surface)
        .onAppear {
            seedConsolePreview {}
        }
}

#Preview("Collapsed — one recent event") {
    SidebarConsoleView()
        .frame(width: 220, height: 80)
        .background(SeeleColors.surface)
        .onAppear {
            seedConsolePreview {
                let log = ActivityLog.shared
                log.logPeerConnected(username: "musicfan42", ip: "192.168.1.100")
            }
        }
}

#Preview("Collapsed — mixed activity") {
    SidebarConsoleView()
        .frame(width: 220, height: 80)
        .background(SeeleColors.surface)
        .onAppear {
            seedConsolePreview {
                let log = ActivityLog.shared
                log.logPeerConnected(username: "vinylcollector", ip: "10.0.0.42")
                log.logSearchStarted(query: "pink floyd dark side flac")
                log.logSearchResults(query: "pink floyd dark side flac", count: 47, user: "vinylcollector")
                log.logDownloadStarted(filename: "Speak to Me.flac", from: "vinylcollector")
            }
        }
}

#Preview("Expanded — full log (click chevron)") {
    SidebarConsoleView()
        .frame(width: 500, height: 800)
        .background(SeeleColors.surface)
        .onAppear {
            seedConsolePreview {
                let log = ActivityLog.shared
                log.logConnectionSuccess(username: "demo_user", server: "server.slsknet.org")
                log.logPeerConnected(username: "vinylcollector", ip: "10.0.0.42")
                log.logSearchStarted(query: "cindy lee diamond jubilee")
                log.logSearchResults(query: "cindy lee diamond jubilee", count: 12, user: "trackhunter")
                log.logSearchResults(query: "cindy lee diamond jubilee", count: 8, user: "archivist99")
                log.logDownloadStarted(filename: "01 - Diamond Jubilee.flac", from: "trackhunter")
                log.logChatMessage(from: "djmixer", room: "Electronic")
                log.logUploadStarted(filename: "Loveless - 01.flac", to: "mbvdevotee")
                log.logDownloadCompleted(filename: "01 - Diamond Jubilee.flac")
                log.logRoomJoined(room: "Electronic", userCount: 834)
                log.logError("Connection refused", detail: "peer unavailable: 203.0.113.1:2234")
                log.logPeerDisconnected(username: "archivist99")
                log.logInfo("NAT mapped port 2234")
                log.logScrollHitch(
                    durationMs: 48,
                    detail: "tab=Search search=412 grouped=0 dl=3(active:1) ul=0(active:0) browseTabs=0 browseExpanded=0 wishlist=2 recent=[Download started,Search result,Search started]"
                )
            }
        }
}
