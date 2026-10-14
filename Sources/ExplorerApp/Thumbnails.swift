import AppKit
import QuickLookThumbnailing
import ExplorerCore

/// Only visible cells subscribe. Four requests at a time, with bounded decoded-image
/// storage; cancelled requests cannot paint a reused cell or repopulate a cleared cache.
@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()
    private final class CacheKey: NSObject {
        let identity: ThumbnailIdentity
        init(_ identity: ThumbnailIdentity) { self.identity = identity }
        override var hash: Int { identity.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? CacheKey)?.identity == identity }
    }
    private struct Job {
        let key: CacheKey
        let request: QLThumbnailGenerator.Request
        let generation: UInt
        let completion: (NSImage) -> Void
    }
    private let cache = NSCache<CacheKey, NSImage>()
    private var generation: UInt = 0
    private var jobs: [UUID: Job] = [:]
    private var queued: [UUID] = []
    private var running: Set<UUID> = []
    private var failures: Set<ThumbnailIdentity> = []
    private init() { cache.totalCostLimit = 64 * 1024 * 1024; cache.countLimit = 512 }

    func request(_ item: FileItem, size: CGFloat, scale: CGFloat, completion: @escaping (NSImage) -> Void) -> UUID? {
        guard !item.isDirectory else { return nil }
        let identity = ThumbnailIdentity(item: item, pixels: Int((size * scale).rounded(.up)))
        let key = CacheKey(identity)
        if let image = cache.object(forKey: key) { completion(image); return nil }
        guard !failures.contains(identity) else { return nil }
        let id = UUID()
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .thumbnail)
        request.iconMode = true
        jobs[id] = Job(key: key, request: request, generation: generation, completion: completion); queued.append(id); pump()
        return id
    }
    func cancel(_ id: UUID?) {
        guard let id, let job = jobs.removeValue(forKey: id) else { return }
        queued.removeAll { $0 == id }
        if running.remove(id) != nil { QLThumbnailGenerator.shared.cancel(job.request) }
        pump()
    }
    func invalidateCache() { generation &+= 1; failures.removeAll(); cache.removeAllObjects() }
    private func pump() {
        while running.count < 4, !queued.isEmpty {
            let id = queued.removeFirst()
            guard let job = jobs[id] else { continue }
            running.insert(id)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: job.request) { [weak self] representation, _ in
                let bitmap = representation?.cgImage
                Task { @MainActor in
                    guard let self, let job = self.jobs.removeValue(forKey: id) else { return }
                    self.running.remove(id)
                    if let bitmap {
                        let image = NSImage(cgImage: bitmap, size: .zero)
                        if job.generation == self.generation { self.cache.setObject(image, forKey: job.key, cost: bitmap.width * bitmap.height * 4) }
                        job.completion(image)
                    } else if job.generation == self.generation {
                        if self.failures.count > 512 { self.failures.removeAll() }
                        self.failures.insert(job.key.identity)
                    }
                    self.pump()
                }
            }
        }
    }
}
