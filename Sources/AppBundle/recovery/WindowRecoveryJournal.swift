import Foundation

/// Window IDs and process IDs are reused. Never restore using an ID alone.
struct RecoveryWindowIdentity: Codable, Equatable {
    let windowId: UInt32
    let pid: Int32
    let bundleId: String?
    let applicationLaunchDate: Date
}

struct RecoveryJournalOwner: Codable, Equatable {
    let pid: Int32
    let bundleId: String?
    let applicationLaunchDate: Date
}

struct RecoveryWindowEntry: Codable, Equatable {
    let identity: RecoveryWindowIdentity
    let originalFrame: CGRect

    var hasValidFrame: Bool {
        originalFrame.origin.x.isFinite && originalFrame.origin.y.isFinite &&
            originalFrame.width.isFinite && originalFrame.height.isFinite &&
            originalFrame.width > 0 && originalFrame.height > 0
    }
}

private struct RecoveryJournalFile: Codable {
    let version: Int
    let sessionId: UUID
    let owner: RecoveryJournalOwner
    let entries: [RecoveryWindowEntry]
}

/// A separate journal from window-state.json: resuming a layout is not crash recovery.
/// All access is serialized on the main actor; the file URL is injectable for tests.
@MainActor
final class WindowRecoveryJournal {
    private let url: URL
    private let owner: RecoveryJournalOwner
    private let sessionId = UUID()
    private(set) var entries: [UInt32: RecoveryWindowEntry] = [:]
    private(set) var carriedIds: Set<UInt32> = []
    private(set) var lastError: String?
    private(set) var canWrite = true
    private var lastSaveAttempt = Date.distantPast

    init(url: URL, owner: RecoveryJournalOwner, isOwnerAlive: (RecoveryJournalOwner) -> Bool) {
        self.url = url
        self.owner = owner
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let file = try JSONDecoder().decode(RecoveryJournalFile.self, from: Data(contentsOf: url))
            guard file.version == 1 else {
                canWrite = false
                lastError = "Unsupported recovery journal version; file preserved."
                return
            }
            guard !isOwnerAlive(file.owner) else {
                canWrite = false
                lastError = "Another running WinMux session owns the recovery journal; file preserved."
                return
            }
            guard Set(file.entries.map { $0.identity.windowId }).count == file.entries.count,
                  file.entries.allSatisfy(\.hasValidFrame) else {
                canWrite = false
                lastError = "Invalid recovery entries; file preserved."
                return
            }
            entries = Dictionary(uniqueKeysWithValues: file.entries.map { ($0.identity.windowId, $0) })
            carriedIds = Set(entries.keys)
        } catch {
            canWrite = false
            lastError = "Unable to read recovery journal; file preserved: \(error.localizedDescription)"
        }
    }

    /// Persist synchronously before the first frame write, not after a debounce that a crash
    /// could interrupt. Keep the original frame across repeated layout passes and restarts.
    func record(identity: RecoveryWindowIdentity, originalFrame: CGRect) {
        guard canWrite else { return }
        if let existing = entries[identity.windowId], existing.identity == identity {
            if lastError != nil, Date().timeIntervalSince(lastSaveAttempt) >= 1 { save() }
            return
        }
        let entry = RecoveryWindowEntry(identity: identity, originalFrame: originalFrame)
        guard entry.hasValidFrame else { return }
        carriedIds.remove(identity.windowId)
        entries[identity.windowId] = entry
        save()
    }

    func recoverableEntries(liveIdentities: [RecoveryWindowIdentity]) -> [RecoveryWindowEntry] {
        let live = Dictionary(liveIdentities.map { ($0.windowId, $0) }, uniquingKeysWith: { _, latest in latest })
        return carriedIds.sorted().compactMap { id in
            guard let entry = entries[id], live[id] == entry.identity else { return nil }
            return entry
        }
    }

    func forget(_ identity: RecoveryWindowIdentity) {
        guard canWrite, entries[identity.windowId]?.identity == identity else { return }
        entries.removeValue(forKey: identity.windowId)
        carriedIds.remove(identity.windowId)
        save()
    }

    /// A clean quit doesn't need crash recovery for this session. Unresolved entries from
    /// an older crash remain available, including failures or disconnected displays.
    func finishCleanly(preserving identities: [RecoveryWindowIdentity] = []) {
        guard canWrite else { return }
        entries = entries.filter { carriedIds.contains($0.key) || identities.contains($0.value.identity) }
        save()
    }

    private func save() {
        guard canWrite else { return }
        lastSaveAttempt = Date()
        do {
            if entries.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let file = RecoveryJournalFile(version: 1, sessionId: sessionId, owner: owner,
                                               entries: entries.values.sorted { $0.identity.windowId < $1.identity.windowId })
                try JSONEncoder().encode(file).write(to: url, options: .atomic)
            }
            lastError = nil
        } catch {
            lastError = "Unable to save recovery journal: \(error.localizedDescription)"
        }
    }
}
