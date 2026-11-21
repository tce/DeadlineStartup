import Foundation

@MainActor
final class WritingTracker: NSObject, ObservableObject {
    static let shared = WritingTracker()
    @Published private(set) var live: [WritingSession] = []
    private var stores: [UUID: Store] = [:]
    private var pending: [UUID: WritingSession] = [:]
    private var timer: Timer?
    private var flushing = false
    private var ticks = 0
    private var preparingToQuit = false
    // Sessions that count only while their application is frontmost.
    private var activeTimed: Set<UUID> = []
    private var activeSince: [UUID: Date] = [:]
    var hasWork: Bool { !live.isEmpty || !pending.isEmpty }

    /// `activeTimeOnly` sessions accumulate time only between `setActive(true)` and
    /// `setActive(false)`; others count wall-clock time until stopped.
    func start(deadline: Deadline, store: Store, application: String, activeTimeOnly: Bool = false, active: Bool = true) -> UUID {
        var session = WritingSession(deadline: deadline)
        session.application = application
        if activeTimeOnly {
            activeTimed.insert(session.id)
            if active { activeSince[session.id] = Date() }
        }
        live.append(session); stores[session.id] = store; pending[session.id] = session
        ensureTimer()
        Task { _ = await flush() }
        return session.id
    }
    func setProject(_ url: String, sessionID: UUID) {
        guard let index = live.firstIndex(where: { $0.id == sessionID }) else { return }
        live[index].projectURL = url; pending[sessionID] = live[index]
    }
    func setActive(_ active: Bool, sessionID: UUID) {
        guard activeTimed.contains(sessionID) else { return }
        checkpoint()
        if active { activeSince[sessionID] = activeSince[sessionID] ?? Date() }
        else { activeSince.removeValue(forKey: sessionID) }
    }
    func stop(_ id: UUID) {
        checkpoint()
        guard let session = live.first(where: { $0.id == id }) else { return }
        pending[id] = session
        live.removeAll { $0.id == id }
        activeTimed.remove(id); activeSince.removeValue(forKey: id)
        Task { _ = await flush() }
    }
    func sessions(in data: SavedData) -> [WritingSession] {
        WritingSession.merging(WritingSession.merging(data.writingSessions ?? [], Array(pending.values)), live)
    }
    private func ensureTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    @objc private func tick() {
        guard !preparingToQuit else { return }
        checkpoint()
        ticks += 1
        if ticks.isMultiple(of: 10) || live.isEmpty { Task { _ = await flush() } }
    }
    private func checkpoint() {
        let now = Date()
        live = live.map { session in
            guard activeTimed.contains(session.id) else { return session.checkpoint(at: now) }
            guard let since = activeSince[session.id] else { return session }
            var copy = session
            copy.seconds += max(0, now.timeIntervalSince(since))
            activeSince[session.id] = now
            return copy
        }
        for session in live { pending[session.id] = session }
    }
    private func flush() async -> Bool {
        guard !flushing else { return false }
        flushing = true
        defer { flushing = false }
        // Preserve other edits by merging into the store's current document.
        let storeIDs = Set(pending.keys.compactMap { stores[$0].map(ObjectIdentifier.init) })
        for storeID in storeIDs {
            guard let store = stores.values.first(where: { ObjectIdentifier($0) == storeID }), !store.isSaving, !store.isLoading else { continue }
            let batch = pending.values.filter { stores[$0.id].map(ObjectIdentifier.init) == storeID }
            var updated = store.data
            updated.writingSessions = WritingSession.merging(updated.writingSessions ?? [], batch)
            if await store.persist(updated) {
                for session in batch {
                    if pending[session.id] == session { pending.removeValue(forKey: session.id) }
                    if !live.contains(where: { $0.id == session.id }) && pending[session.id] == nil { stores.removeValue(forKey: session.id) }
                }
            }
        }
        if !hasWork { timer?.invalidate(); timer = nil }
        return pending.isEmpty
    }
    func prepareForQuit() async -> Bool {
        // Count to the quit request, then wait for any document save to finish.
        preparingToQuit = true
        defer { preparingToQuit = false }
        checkpoint()
        for _ in 0..<100 {
            if !flushing && !stores.values.contains(where: { $0.isSaving || $0.isLoading }) { return await flush() }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
