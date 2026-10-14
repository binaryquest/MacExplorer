import Foundation

public struct PaneSession: Codable, Equatable, Sendable {
    public var paths: [String]
    public var active: Int
    public var modes: [String]
    public var presentations: [TabPresentation]?
    public init(paths: [String], active: Int = 0, modes: [String] = [], presentations: [TabPresentation]? = nil) {
        let valid = Array(paths.enumerated().filter { BrowserLocation.restored($0.element) != nil }.prefix(20))
        self.paths = valid.map(\.element)
        self.modes = valid.map { modes.indices.contains($0.offset) ? modes[$0.offset] : "" }
        self.presentations = presentations.map { values in valid.map { values.indices.contains($0.offset) ? values[$0.offset] : TabPresentation() } }
        self.active = valid.firstIndex(where: { $0.offset == active }) ?? min(max(active, 0), max(0, self.paths.count - 1))
    }
    public var sanitized: Self { Self(paths: paths, active: active, modes: modes, presentations: presentations) }
}
public struct WorkspaceSession: Codable, Equatable, Sendable {
    public var left: PaneSession
    public var right: PaneSession?
    public var dualPane: Bool
    public var activeRight: Bool
    public init(left: PaneSession, right: PaneSession? = nil, dualPane: Bool = false, activeRight: Bool = false) {
        self.left = left.sanitized; self.right = right?.sanitized
        self.dualPane = dualPane && right != nil; self.activeRight = activeRight && self.dualPane
    }
    public var sanitized: Self { Self(left: left, right: right, dualPane: dualPane, activeRight: activeRight) }
}
