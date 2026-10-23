import Foundation

/// A rectangle with a top-left origin (y grows downward).
public struct Rect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public static let unit = Rect(x: 0, y: 0, width: 1000, height: 1000)
}

/// Which way a split divides its space.
public enum SplitAxis: String, Sendable, Codable {
    /// Children side by side (a "split right").
    case horizontal
    /// Children stacked (a "split down").
    case vertical
}

public enum Direction: String, Sendable, Codable, CaseIterable {
    case left, right, up, down

    /// The split axis that moving in this direction crosses.
    public var axis: SplitAxis {
        switch self {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }

    /// True for right and down, where the ratio grows.
    var isForward: Bool { self == .right || self == .down }
}

/// One node of the pane tree. Leaves hold pane ids.
public indirect enum LayoutNode: Equatable, Sendable {
    case leaf(Int)
    case split(SplitAxis, ratio: Double, first: LayoutNode, second: LayoutNode)

    /// Pane ids in reading order (left to right, top to bottom).
    public var leaves: [Int] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, let first, let second): return first.leaves + second.leaves
        }
    }

    public func contains(_ id: Int) -> Bool {
        switch self {
        case .leaf(let leaf): return leaf == id
        case .split(_, _, let first, let second): return first.contains(id) || second.contains(id)
        }
    }

    func replacingLeaf(_ id: Int, with node: LayoutNode) -> LayoutNode {
        switch self {
        case .leaf(let leaf):
            return leaf == id ? node : self
        case .split(let axis, let ratio, let first, let second):
            return .split(axis, ratio: ratio,
                          first: first.replacingLeaf(id, with: node),
                          second: second.replacingLeaf(id, with: node))
        }
    }

    /// The node without `id`, or nil when nothing is left.
    func removing(_ id: Int) -> LayoutNode? {
        switch self {
        case .leaf(let leaf):
            return leaf == id ? nil : self
        case .split(let axis, let ratio, let first, let second):
            let newFirst = first.removing(id)
            let newSecond = second.removing(id)
            guard let newFirst else { return newSecond }
            guard let newSecond else { return newFirst }
            return .split(axis, ratio: ratio, first: newFirst, second: newSecond)
        }
    }
}

/// A draggable boundary between the two children of a split.
public struct Divider: Equatable, Sendable {
    /// Path from the root to the split node: 0 = first child, 1 = second child.
    public var path: [Int]
    public var axis: SplitAxis
    /// The gap between the two children.
    public var rect: Rect
    /// The whole area of the split node, used to turn a mouse position into a ratio.
    public var parent: Rect
}

/// The pane layout of one tab: a binary tree of splits with pane ids at the leaves.
public struct LayoutTree: Equatable, Sendable {
    public private(set) var root: LayoutNode

    public static let minRatio = 0.1
    public static let maxRatio = 0.9

    public init(pane: Int) {
        root = .leaf(pane)
    }

    public init(root: LayoutNode) {
        self.root = root
    }

    public var leaves: [Int] { root.leaves }
    public var count: Int { leaves.count }
    public func contains(_ id: Int) -> Bool { root.contains(id) }

    /// Splits `pane` in two. The new pane goes to the right (horizontal) or below (vertical).
    @discardableResult
    public mutating func split(_ pane: Int, axis: SplitAxis, newPane: Int) -> Bool {
        guard contains(pane), !contains(newPane) else { return false }
        root = root.replacingLeaf(pane, with: .split(axis, ratio: 0.5, first: .leaf(pane), second: .leaf(newPane)))
        return true
    }

    /// Removes a pane; its sibling takes the space. The last pane cannot be removed.
    @discardableResult
    public mutating func remove(_ pane: Int) -> Bool {
        guard contains(pane), count > 1, let newRoot = root.removing(pane) else { return false }
        root = newRoot
        return true
    }

    /// The frame of every pane when the tree fills `rect`, with `gap` points between panes.
    public func frames(in rect: Rect, gap: Double = 0) -> [Int: Rect] {
        var result: [Int: Rect] = [:]
        func walk(_ node: LayoutNode, _ rect: Rect) {
            switch node {
            case .leaf(let id):
                result[id] = rect
            case .split(let axis, let ratio, let first, let second):
                let (a, b) = Self.divide(rect, axis: axis, ratio: ratio, gap: gap)
                walk(first, a)
                walk(second, b)
            }
        }
        walk(root, rect)
        return result
    }

    /// Every divider, for drawing and mouse dragging.
    public func dividers(in rect: Rect, gap: Double = 0) -> [Divider] {
        var result: [Divider] = []
        func walk(_ node: LayoutNode, _ rect: Rect, _ path: [Int]) {
            guard case .split(let axis, let ratio, let first, let second) = node else { return }
            let (a, b) = Self.divide(rect, axis: axis, ratio: ratio, gap: gap)
            let strip: Rect
            switch axis {
            case .horizontal: strip = Rect(x: a.maxX, y: rect.y, width: b.minX - a.maxX, height: rect.height)
            case .vertical: strip = Rect(x: rect.x, y: a.maxY, width: rect.width, height: b.minY - a.maxY)
            }
            result.append(Divider(path: path, axis: axis, rect: strip, parent: rect))
            walk(first, a, path + [0])
            walk(second, b, path + [1])
        }
        walk(root, rect, [])
        return result
    }

    /// Sets the ratio of the split at `path` (clamped).
    public mutating func setRatio(at path: [Int], to ratio: Double) {
        func update(_ node: LayoutNode, _ path: ArraySlice<Int>) -> LayoutNode {
            guard case .split(let axis, let old, let first, let second) = node else { return node }
            guard let step = path.first else {
                return .split(axis, ratio: Self.clamp(ratio), first: first, second: second)
            }
            let rest = path.dropFirst()
            return step == 0
                ? .split(axis, ratio: old, first: update(first, rest), second: second)
                : .split(axis, ratio: old, first: first, second: update(second, rest))
        }
        root = update(root, path[...])
    }

    /// The pane next to `pane` in a direction, picked by on-screen position.
    public func neighbor(of pane: Int, direction: Direction, in rect: Rect = .unit) -> Int? {
        let all = frames(in: rect)
        guard let from = all[pane] else { return nil }
        let eps = 0.5
        var best: (id: Int, distance: Double, overlap: Double)?
        // Walk in reading order so ties always go to the top-left-most pane.
        for id in leaves where id != pane {
            guard let frame = all[id] else { continue }
            let distance: Double
            let overlap: Double
            switch direction {
            case .right:
                guard frame.minX >= from.maxX - eps else { continue }
                distance = frame.minX - from.maxX
                overlap = min(frame.maxY, from.maxY) - max(frame.minY, from.minY)
            case .left:
                guard frame.maxX <= from.minX + eps else { continue }
                distance = from.minX - frame.maxX
                overlap = min(frame.maxY, from.maxY) - max(frame.minY, from.minY)
            case .down:
                guard frame.minY >= from.maxY - eps else { continue }
                distance = frame.minY - from.maxY
                overlap = min(frame.maxX, from.maxX) - max(frame.minX, from.minX)
            case .up:
                guard frame.maxY <= from.minY + eps else { continue }
                distance = from.minY - frame.maxY
                overlap = min(frame.maxX, from.maxX) - max(frame.minX, from.minX)
            }
            guard overlap > eps else { continue }
            if let current = best {
                if distance < current.distance - eps
                    || (abs(distance - current.distance) <= eps && overlap > current.overlap) {
                    best = (id, distance, overlap)
                }
            } else {
                best = (id, distance, overlap)
            }
        }
        return best?.id
    }

    /// The pane after `pane` in reading order, wrapping around.
    public func next(after pane: Int) -> Int? {
        let list = leaves
        guard let index = list.firstIndex(of: pane) else { return nil }
        return list[(index + 1) % list.count]
    }

    /// The pane before `pane` in reading order, wrapping around.
    public func previous(before pane: Int) -> Int? {
        let list = leaves
        guard let index = list.firstIndex(of: pane) else { return nil }
        return list[(index + list.count - 1) % list.count]
    }

    /// Moves the nearest divider around `pane` that runs across `direction`, by `delta` (a ratio).
    /// Returns false when there is no such divider.
    @discardableResult
    public mutating func resize(_ pane: Int, direction: Direction, by delta: Double = 0.05) -> Bool {
        guard let path = pathTo(pane) else { return false }
        // Walk up from the leaf and find the closest split with the right axis.
        var node = root
        var nodes: [LayoutNode] = [root]
        for step in path {
            guard case .split(_, _, let first, let second) = node else { break }
            node = step == 0 ? first : second
            nodes.append(node)
        }
        for depth in stride(from: path.count - 1, through: 0, by: -1) {
            guard case .split(let axis, let ratio, _, _) = nodes[depth], axis == direction.axis else { continue }
            let change = direction.isForward ? delta : -delta
            setRatio(at: Array(path[0..<depth]), to: ratio + change)
            return true
        }
        return false
    }

    /// Path from the root to a leaf (0 = first child, 1 = second child).
    public func pathTo(_ pane: Int) -> [Int]? {
        func find(_ node: LayoutNode, _ path: [Int]) -> [Int]? {
            switch node {
            case .leaf(let id):
                return id == pane ? path : nil
            case .split(_, _, let first, let second):
                return find(first, path + [0]) ?? find(second, path + [1])
            }
        }
        return find(root, [])
    }

    static func clamp(_ ratio: Double) -> Double {
        min(max(ratio, minRatio), maxRatio)
    }

    static func divide(_ rect: Rect, axis: SplitAxis, ratio: Double, gap: Double) -> (Rect, Rect) {
        switch axis {
        case .horizontal:
            let usable = max(rect.width - gap, 0)
            let firstWidth = (usable * ratio).rounded()
            return (Rect(x: rect.x, y: rect.y, width: firstWidth, height: rect.height),
                    Rect(x: rect.x + firstWidth + gap, y: rect.y, width: usable - firstWidth, height: rect.height))
        case .vertical:
            let usable = max(rect.height - gap, 0)
            let firstHeight = (usable * ratio).rounded()
            return (Rect(x: rect.x, y: rect.y, width: rect.width, height: firstHeight),
                    Rect(x: rect.x, y: rect.y + firstHeight + gap, width: rect.width, height: usable - firstHeight))
        }
    }
}
