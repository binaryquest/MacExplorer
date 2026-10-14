import Foundation

/// Insertion slots are boundaries in the original strip (0...count), not item indexes.
public enum TabPlacement {
    public static func destination(from source: Int, before slot: Int, count: Int) -> Int? {
        guard count > 0, (0..<count).contains(source), (0...count).contains(slot) else { return nil }
        return slot > source ? slot - 1 : slot
    }

    public static func shouldDetach(accepted: Bool, cancelled: Bool, mouseReleased: Bool,
                                    outsideSourceWindow: Bool) -> Bool {
        !accepted && !cancelled && mouseReleased && outsideSourceWindow
    }
}
