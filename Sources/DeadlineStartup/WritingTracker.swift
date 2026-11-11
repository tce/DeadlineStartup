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
    var hasWork: Bool { !live.isEmpty || !pending.isEmpty }

    func start(deadline: Deadline, store: Store) -> UUID {
        let session = WritingSession(deadline: deadline)
        live.append(session); stores[session.id] = store; pending[session.id] = session
        ensureTimer()
        Task { _ = await flush() }
        return session.id
    }
    func setProject(_ url: String, sessionID: UUID) {
        guard let index = live.firstIndex(where: { $0.id == sessionID }) else { return }
        live[index].projectURL = url; pending[sessionID] = live[index]
    }
    func stop(_ id: UUID) {
        guard let session = live.first(where: { $0.id == id }) else { return }
        pending[id] = session.checkpoint(at: Date())
        live.removeAll { $0.id == id }
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
        live = live.map { $0.checkpoint(at: now) }
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
