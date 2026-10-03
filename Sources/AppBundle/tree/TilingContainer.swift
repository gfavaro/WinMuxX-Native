import AppKit
import Common

final class TilingContainer: TreeNode, NonLeafTreeNodeObject { // todo consider renaming to GenericContainer
    fileprivate var _orientation: Orientation
    var orientation: Orientation { _orientation }
    var layout: Layout
    // Each entry controls a child versus the remaining subtree, not sibling weights.
    var dwindleSplitRatios: [CGFloat] = []
    // nil resolves each split from the available rectangle.
    var dwindleOrientation: Orientation?

    func restoreNativeCheckpointLayout(_ orientation: Orientation, _ layout: Layout, _ ratios: [CGFloat], _ dwindle: Orientation?) {
        _orientation = orientation
        self.layout = layout
        dwindleSplitRatios = ratios
        dwindleOrientation = dwindle
    }

    func dwindleAxis(width: CGFloat, height: CGFloat) -> Orientation {
        dwindleOrientation ?? (width >= height ? .h : .v)
    }

    @MainActor
    var navigationOrientation: Orientation {
        guard layout == .dwindle else { return orientation }
        let rect = lastAppliedLayoutPhysicalRect ?? nodeMonitor?.visibleRectPaddedByOuterGaps
        return rect.map { dwindleAxis(width: $0.width, height: $0.height) } ?? dwindleOrientation ?? orientation
    }

    func dwindleShares(count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        var remaining: CGFloat = 1
        return (0..<count).map { index in
            let share = index == count - 1 ? remaining : remaining * dwindleSplitRatio(at: index)
            remaining -= share
            return share
        }
    }

    func setDwindleShares(_ shares: [CGFloat]) {
        var remaining = shares.reduce(0, +)
        dwindleSplitRatios = shares.dropLast().map { share in
            let ratio = remaining > 0 ? share / remaining : 0.5
            remaining -= share
            return min(max(ratio, 0.1), 0.9)
        }
    }

    func dwindleChildWillInsert(at index: Int) {
        guard layout == .dwindle, !dwindleSplitRatios.isEmpty else { return }
        var shares = dwindleShares(count: children.count)
        guard !shares.isEmpty else { return }
        let donor = min(max(index - 1, 0), shares.count - 1)
        let share = shares[donor] / 2
        shares[donor] = share
        shares.insert(share, at: index)
        setDwindleShares(shares)
    }

    func dwindleChildWillRemove(at index: Int) {
        guard layout == .dwindle else { return }
        var shares = dwindleShares(count: children.count)
        shares.remove(at: index)
        setDwindleShares(shares)
    }

    func dwindleSplitRatio(at index: Int) -> CGFloat {
        guard dwindleSplitRatios.indices.contains(index), dwindleSplitRatios[index].isFinite else { return 0.5 }
        return min(max(dwindleSplitRatios[index], 0.1), 0.9)
    }

    func setDwindleSplitRatio(_ ratio: CGFloat, at index: Int) {
        guard index >= 0, index < children.count - 1, ratio.isFinite else { return }
        if dwindleSplitRatios.count <= index {
            dwindleSplitRatios.append(contentsOf: repeatElement(0.5, count: index + 1 - dwindleSplitRatios.count))
        }
        dwindleSplitRatios[index] = min(max(ratio, 0.1), 0.9)
    }

    @MainActor
    init(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, _ orientation: Orientation, _ layout: Layout, index: Int) {
        self._orientation = orientation
        self.layout = layout
        if parent is Workspace, layout == .dwindle {
            dwindleOrientation = switch config.defaultRootContainerOrientation {
                case .auto: nil
                case .horizontal: .h
                case .vertical: .v
            }
        }
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor
    static func newHTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> TilingContainer {
        TilingContainer(parent: parent, adaptiveWeight: adaptiveWeight, .h, .tiles, index: index)
    }

    @MainActor
    static func newVTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> TilingContainer {
        TilingContainer(parent: parent, adaptiveWeight: adaptiveWeight, .v, .tiles, index: index)
    }
}

extension TilingContainer {
    var isRootContainer: Bool { parent is Workspace }

    @MainActor
    func changeOrientation(_ targetOrientation: Orientation) {
        if orientation == targetOrientation {
            return
        }
        if config.enableNormalizationOppositeOrientationForNestedContainers {
            var orientation = targetOrientation
            parentsWithSelf
                .filterIsInstance(of: TilingContainer.self)
                .forEach {
                    $0._orientation = orientation
                    orientation = orientation.opposite
                }
        } else {
            _orientation = targetOrientation
        }
    }

    func normalizeOppositeOrientationForNestedContainers() {
        if orientation == (parent as? TilingContainer)?.orientation {
            _orientation = orientation.opposite
        }
        for child in children {
            (child as? TilingContainer)?.normalizeOppositeOrientationForNestedContainers()
        }
    }
}

enum Layout: String, Codable {
    case tiles
    case tabGroup = "tab-group"
    case dwindle
}

extension String {
    func parseLayout() -> Layout? {
        Layout(rawValue: self)
    }
}
