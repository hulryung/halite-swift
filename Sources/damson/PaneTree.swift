import AppKit
import DamsonTerminal

/// Split 방향. horizontal = 좌우로 나란히 (vertical divider),
/// vertical = 위아래로 쌓임 (horizontal divider). 명칭은 iTerm2 관행.
enum SplitDirection {
    case horizontal  // 좌/우
    case vertical    // 위/아래
}

/// Split tree 노드. leaf(단일 session) 또는 split(direction + 두 child + ratio).
/// reference 의미가 필요하므로 class 기반.
final class PaneNode {
    enum Kind {
        case leaf(session: DamsonSession, surface: DamsonSurfaceView)
        case split(direction: SplitDirection, first: PaneNode, second: PaneNode, ratio: CGFloat)
    }
    var kind: Kind
    weak var parent: PaneNode?

    init(kind: Kind) {
        self.kind = kind
    }

    static func leaf(_ session: DamsonSession) -> PaneNode {
        let surface = DamsonSurfaceView(session: session)
        surface.translatesAutoresizingMaskIntoConstraints = false
        return PaneNode(kind: .leaf(session: session, surface: surface))
    }

    var isLeaf: Bool {
        if case .leaf = kind { return true }
        return false
    }

    /// 트리의 모든 leaf를 in-order로 순회.
    func leaves() -> [(session: DamsonSession, surface: DamsonSurfaceView)] {
        switch kind {
        case .leaf(let s, let v):
            return [(s, v)]
        case .split(_, let a, let b, _):
            return a.leaves() + b.leaves()
        }
    }

    /// 이 노드의 모든 session terminate.
    func terminateAll() {
        for (s, _) in leaves() { s.terminate() }
    }
}
