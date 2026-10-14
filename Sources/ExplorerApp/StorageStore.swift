import AppKit
import ExplorerCore

@MainActor
final class StorageStore {
    static let shared = StorageStore()
    static let changed = Notification.Name("ExplorerStorageChanged")
    private(set) var locations: [StorageLocation] = []
    private(set) var refreshing = false
    private var volumes: [String: StorageLocation] = [:]
    private var clouds: [String: StorageLocation] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var generation = UUID()
    private var pending = 0
    private var refreshedAt = Date.distantPast
    private init() {
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumesChanged), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(activated), name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    @objc private func volumesChanged() { refresh() }
    @objc private func activated() { refreshIfNeeded() }
    func refreshIfNeeded() { if pending == 0 && !refreshing && Date().timeIntervalSince(refreshedAt) > 30 { refresh() } }
    func refresh() {
        if DemoData.active {
            locations = DemoData.locations; refreshedAt = Date(); refreshing = false
            NotificationCenter.default.post(name: Self.changed, object: nil); return
        }
        tasks.forEach { $0.cancel() }; tasks = []; generation = UUID()
        let token = generation, home = FileManager.default.homeDirectoryForCurrentUser
        refreshing = true; pending = 1; publish()
        // Slow/offline file providers can keep a filesystem call waiting. Keep
        // their root available and stop the spinner; late results still update.
        tasks.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.generation == token, self.refreshing else { return }
            self.refreshing = false; self.refreshedAt = Date(); self.publish()
        })
        tasks.append(Task { [weak self] in
            let urls = await Task.detached(priority: .utility) { StorageDiscovery.volumeURLs() }.value
            guard let self, self.generation == token else { return }
            let paths = Set(urls.map(\.path)); self.volumes = self.volumes.filter { paths.contains($0.key) }
            // Show all mounted drives immediately, then fill each capacity independently.
            for url in urls {
                if self.volumes[url.path] == nil { self.volumes[url.path] = StorageLocation(url: url, title: url.path == "/" ? "Macintosh HD" : url.lastPathComponent, detail: "Reading storage…", kind: url.path == "/" ? .internalDrive : .externalDrive) }
                self.pending += 1
                self.tasks.append(Task { [weak self] in
                    let location = await Task.detached(priority: .utility) { StorageDiscovery.volume(url) }.value
                    guard let self, self.generation == token else { return }
                    self.volumes[location.id] = location; self.finishedOne()
                })
            }
            self.publish()
            let roots = await Task.detached(priority: .utility) { StorageDiscovery.cloudRoots(home: home, mounted: urls) }.value
            guard self.generation == token else { return }
            let rootPaths = Set(roots.map(\.path)); self.clouds = self.clouds.filter { rootPaths.contains($0.key) }
            for root in roots {
                if self.clouds[root.path] == nil { self.clouds[root.path] = StorageDiscovery.cloudRoot(root) }
                self.pending += 1
                self.tasks.append(Task { [weak self] in
                    let location = await Task.detached(priority: .utility) { StorageDiscovery.cloud(root) }.value
                    guard let self, self.generation == token else { return }
                    self.clouds[location.id] = location; self.finishedOne()
                })
            }
            self.finishedOne()
        })
    }
    private func finishedOne() {
        pending -= 1
        if pending == 0 { refreshing = false; refreshedAt = Date() }
        publish()
    }
    private func publish() {
        locations = (volumes.filter { clouds[$0.key] == nil }.map(\.value) + clouds.values).sorted {
            if ($0.url.path == "/") != ($1.url.path == "/") { return $0.url.path == "/" }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
