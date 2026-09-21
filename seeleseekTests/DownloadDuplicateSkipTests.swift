import Foundation
import Testing
@testable import SeeleseekCore

@MainActor
@Suite("Download duplicate skip")
struct DownloadDuplicateSkipTests {
    private func makeResult(username: String = "alice", filename: String = "@@music\\Album\\track.mp3") -> SearchResult {
        SearchResult(username: username, filename: filename, size: 1_024)
    }

    private func makeTransfer(
        username: String = "alice",
        filename: String = "@@music\\Album\\track.mp3",
        status: Transfer.TransferStatus
    ) -> Transfer {
        Transfer(
            username: username,
            filename: filename,
            size: 1_024,
            direction: .download,
            status: status
        )
    }

    private func configuredManager(downloadDir: URL) async -> (DownloadManager, MockTransferTracking) {
        let manager = DownloadManager()
        let tracking = MockTransferTracking()
        await manager._setTransferStateForTest(tracking)
        await manager._setNetworkClientForTest(NetworkClient())
        await manager._setSettingsForTest(DownloadSettingsSnapshot(
            downloadLocation: downloadDir,
            activeDownloadTemplate: "{folder}/{filename}",
            incompleteDownloadDirectory: downloadDir.appendingPathComponent("Incomplete"),
            setFolderIcons: false
        ))
        return (manager, tracking)
    }

    @Test("Completed transfer is not re-queued")
    func skipsCompletedTransfer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (manager, tracking) = await configuredManager(downloadDir: dir)
        let done = makeTransfer(status: .completed)
        tracking.downloads = [done]

        await manager.queueDownload(from: makeResult())

        #expect(tracking.downloads.count == 1)
        #expect(tracking.downloads.first?.status == .completed)
        #expect(tracking.downloads.first?.id == done.id)
    }

    @Test("File already at destination is not queued")
    func skipsFileOnDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (manager, tracking) = await configuredManager(downloadDir: dir)
        let result = makeResult()
        let dest = await manager._destinationForTest(soulseekPath: result.filename, username: result.username)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("already here".utf8).write(to: dest)

        await manager.queueDownload(from: result)

        #expect(tracking.downloads.isEmpty)
    }

    @Test("Failed transfer without on-disk file can be re-queued")
    func requeuesFailedWhenMissingOnDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (manager, tracking) = await configuredManager(downloadDir: dir)
        let failed = makeTransfer(status: .failed)
        tracking.downloads = [failed]

        await manager.queueDownload(from: makeResult())

        #expect(tracking.downloads.count == 1)
        #expect(tracking.downloads.first?.status == .queued)
        #expect(tracking.downloads.first?.id == failed.id)
    }

    @Test("Failed transfer with on-disk file is skipped")
    func skipsFailedWhenOnDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (manager, tracking) = await configuredManager(downloadDir: dir)
        let result = makeResult()
        let failed = makeTransfer(status: .failed)
        tracking.downloads = [failed]
        let dest = await manager._destinationForTest(soulseekPath: result.filename, username: result.username)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("already here".utf8).write(to: dest)

        await manager.queueDownload(from: result)

        #expect(tracking.downloads.count == 1)
        #expect(tracking.downloads.first?.status == .failed)
    }
}
