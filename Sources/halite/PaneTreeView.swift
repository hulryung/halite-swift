import AppKit
import HaliteTerminal

/// Pane focus 이동 방향 (Cmd+Opt+화살표).
enum PaneFocusDirection {
    case left, right, up, down
}

/// PaneNode 트리를 화면에 배치하는 NSView. divider drag로 ratio 조정 + leaf 클릭으로
/// active pane 선택. Cmd+D / Cmd+Shift+D 로 split, Cmd+W 로 active pane 닫기.
final class PaneTreeView: NSView {
    private(set) var root: PaneNode
    private(set) var activeLeaf: PaneNode

    /// 마지막 leaf가 닫혔을 때 호출 (호스트 — 탭 컨트롤러 — 가 탭/윈도우를 닫음).
    var onAllPanesClosed: (() -> Void)?

    /// Pane lifecycle animation intent threaded through `rebuild`. `.none` is the
    /// instant/legacy path; `.split` animates the newly-created pane in from the
    /// divider edge. (`.close` is added in Task 5 — do not add it here.)
    private enum PaneAnimation {
        case none
        /// After rebuild, find the wrapper whose leaf === `newLeaf` and animate it in.
        case split(newLeaf: PaneNode)
    }

    init(rootSession: HaliteSession) {
        let leaf = PaneNode.leaf(rootSession)
        self.root = leaf
        self.activeLeaf = leaf
        super.init(frame: .zero)
        wantsLayer = true
        rebuild()
    }

    /// 세션 복원 — 이미 구성된 PaneNode 트리로 생성. active는 첫 leaf.
    init(restoredRoot: PaneNode) {
        self.root = restoredRoot
        self.activeLeaf = PaneTreeView.firstLeafStatic(of: restoredRoot)
        super.init(frame: .zero)
        wantsLayer = true
        rebuild()
    }

    private static func firstLeafStatic(of node: PaneNode) -> PaneNode {
        switch node.kind {
        case .leaf: return node
        case .split(_, let a, _, _): return firstLeafStatic(of: a)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        root.terminateAll()
    }

    // MARK: - Public actions

    func split(direction: SplitDirection) {
        guard case .leaf = activeLeaf.kind else { return }
        let newSession = HaliteSession(config: HaliteConfig.fromUserDefaults())
        let newLeaf = PaneNode.leaf(newSession)
        let oldKind = activeLeaf.kind
        // activeLeaf의 kind를 split으로 교체. activeLeaf 인스턴스는 그대로 (parent 링크 보존).
        let oldLeafCopy = PaneNode(kind: oldKind)
        oldLeafCopy.parent = activeLeaf
        newLeaf.parent = activeLeaf
        activeLeaf.kind = .split(
            direction: direction,
            first: oldLeafCopy,
            second: newLeaf,
            ratio: 0.5
        )
        activeLeaf = newLeaf
        // Animate the new pane in only when motion is enabled (live transform,
        // no snapshot → the only gate is Motion.enabled). Otherwise the instant
        // path (rebuild(animation: .none)) — identical end state to today.
        rebuild(animation: Motion.enabled ? .split(newLeaf: newLeaf) : .none)
    }

    func closeActive() {
        guard case .leaf = activeLeaf.kind else { return }
        // session terminate.
        if case .leaf(let s, _) = activeLeaf.kind {
            s.terminate()
        }
        // 부모의 다른 child가 그 부모 자리로 promote.
        guard let parent = activeLeaf.parent,
              case .split(_, let first, let second, _) = parent.kind
        else {
            // root leaf 닫은 경우 — 전체 종료.
            onAllPanesClosed?()
            return
        }
        let sibling = (first === activeLeaf) ? second : first
        parent.kind = sibling.kind
        // sibling이 split이었으면 그 자식들의 parent를 갱신.
        if case .split(_, let a, let b, _) = parent.kind {
            a.parent = parent
            b.parent = parent
        }
        // 새 active를 promote된 sub-tree의 첫 leaf로 설정.
        activeLeaf = firstLeaf(of: parent)
        rebuild()
    }

    /// 마우스 클릭 등으로 외부에서 active pane 변경 호출.
    func setActive(_ leaf: PaneNode) {
        guard case .leaf = leaf.kind else { return }
        activeLeaf = leaf
        updateBorderColors()
        if case .leaf(_, let surface) = leaf.kind {
            window?.makeFirstResponder(surface)
        }
    }

    /// Cmd+Opt+화살표 — 현재 active pane의 화면 위치 기준으로 방향상 가장 가까운
    /// 인접 pane으로 focus 이동. leaf wrapper들의 self 좌표계 frame을 사용.
    func moveFocus(_ dir: PaneFocusDirection) {
        var wrappers: [PaneLeafWrapper] = []
        func collect(_ v: NSView) {
            if let w = v as? PaneLeafWrapper { wrappers.append(w) }
            for sub in v.subviews { collect(sub) }
        }
        collect(self)
        guard wrappers.count >= 2,
              let current = wrappers.first(where: { $0.leaf === activeLeaf })
        else { return }

        let cur = current.convert(current.bounds, to: self)
        let curMid = NSPoint(x: cur.midX, y: cur.midY)

        // 방향에 맞는 후보만 추리고 (해당 축으로 분명히 떨어진 것), 중심 거리 최소 선택.
        var best: PaneLeafWrapper?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for w in wrappers where w !== current {
            let f = w.convert(w.bounds, to: self)
            let mid = NSPoint(x: f.midX, y: f.midY)
            let dx = mid.x - curMid.x
            let dy = mid.y - curMid.y
            // self는 non-flipped(y up). up = y 증가, down = y 감소.
            let matches: Bool
            switch dir {
            case .left: matches = dx < -1
            case .right: matches = dx > 1
            case .up: matches = dy > 1
            case .down: matches = dy < -1
            }
            guard matches else { continue }
            let dist = dx * dx + dy * dy
            if dist < bestDist { bestDist = dist; best = w }
        }
        if let target = best { setActive(target.leaf) }
    }

    // MARK: - Tree → NSView 재구성

    private func rebuild(animation: PaneAnimation = .none) {
        for sub in subviews { sub.removeFromSuperview() }
        addSubviewsForNode(root, into: self)
        updateBorderColors()
        if case .leaf(_, let surface) = activeLeaf.kind {
            window?.makeFirstResponder(surface)
        }
        needsLayout = true

        // Animate the appearing pane AFTER the new hierarchy + first responder
        // are in their final state (focus/typing already works mid-animation).
        switch animation {
        case .none:
            break
        case .split(let newLeaf):
            // Determine which axis to nudge along from the new leaf's parent split.
            guard let parent = newLeaf.parent,
                  case .split(let dir, _, _, _) = parent.kind
            else { break }
            animateSplitIn(newLeaf: newLeaf, direction: dir)
        }
    }

    private func addSubviewsForNode(_ node: PaneNode, into container: NSView) {
        switch node.kind {
        case .leaf(_, let surface):
            // leaf 컨테이너 — border 표시용 wrapper. frame + autoresizing 으로 fill.
            let wrapper = PaneLeafWrapper(leaf: node, owner: self)
            wrapper.translatesAutoresizingMaskIntoConstraints = true
            wrapper.autoresizingMask = [.width, .height]
            wrapper.frame = container.bounds
            container.addSubview(wrapper)
            // surface는 autolayout으로 wrapper를 1pt border 안쪽으로 fill.
            surface.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(surface)
            NSLayoutConstraint.activate([
                surface.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 1),
                surface.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -1),
                surface.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 1),
                surface.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -1),
            ])

        case .split(_, let first, let second, _):
            // split — 두 sub-area + divider. SplitContainer의 layout()이 frame 계산
            // (direction/ratio는 node.kind에서 직접 읽으므로 여기선 바인딩 불필요).
            let splitContainer = SplitContainer(node: node, owner: self)
            splitContainer.translatesAutoresizingMaskIntoConstraints = true
            splitContainer.autoresizingMask = [.width, .height]
            splitContainer.frame = container.bounds
            container.addSubview(splitContainer)
            addSubviewsForNode(first, into: splitContainer.firstContainer)
            addSubviewsForNode(second, into: splitContainer.secondContainer)
        }
    }

    // MARK: - Split/Close animation helpers

    /// Recursively find the `PaneLeafWrapper` whose `leaf` is identical (===) to
    /// `target`. Walks the freshly-rebuilt subtree; returns nil if not found.
    /// Used by both the split-in (Task 3) and close (Task 5) animations.
    private func findWrapper(for target: PaneNode, in view: NSView) -> PaneLeafWrapper? {
        if let w = view as? PaneLeafWrapper, w.leaf === target {
            return w
        }
        for sub in view.subviews {
            if let found = findWrapper(for: target, in: sub) { return found }
        }
        return nil
    }

    /// Animate the new pane "opening from the split line": its wrapper is already
    /// at the final half-frame, so we animate the wrapper's `layer.transform` from
    /// a small nudge toward the divider back to identity, plus opacity 0→1.
    /// Pure visual layer animation — the live surface is never resized (no reflow).
    private func animateSplitIn(newLeaf: PaneNode, direction: SplitDirection) {
        // The wrapper's final half-frame is computed by SplitContainer.layout(),
        // which only runs during a layout pass. Force it now so wrapper.bounds is
        // final before we read it.
        layoutSubtreeIfNeeded()

        guard let wrapper = findWrapper(for: newLeaf, in: self),
              let layer = wrapper.layer,
              wrapper.bounds.width > 0, wrapper.bounds.height > 0
        else { return }

        // Small "nudge", not a full traverse, to keep the motion subtle.
        // The new pane is always `second`: right of the divider (horizontal) or
        // below it (vertical). All views here are non-flipped (y grows upward),
        // matching SplitContainer.layout()'s bottom-up coordinate comments.
        let fromTransform: CATransform3D
        switch direction {
        case .horizontal:
            // New pane sits to the RIGHT of the divider → start nudged LEFT
            // (toward the divider, -x) and settle right into place.
            let dx = -min(24, wrapper.bounds.width * 0.06)
            fromTransform = CATransform3DMakeTranslation(dx, 0, 0)
        case .vertical:
            // New pane sits BELOW the divider (lower y in bottom-up coords) →
            // start nudged UP toward the divider (+y) and settle down into place.
            let dy = min(24, wrapper.bounds.height * 0.06)
            fromTransform = CATransform3DMakeTranslation(0, dy, 0)
        }

        // Set the final state on the MODEL layer first, then add explicit
        // "from → identity" animations (same idiom as the bell-flash
        // CABasicAnimation in HaliteTerminalView). The model values are at their
        // final identity/1.0 state BEFORE add(), so when the animation finishes
        // (or is removed) the layer rests where it already is. Driven by
        // Motion.duration / Motion.timing only.
        layer.transform = CATransform3DIdentity
        layer.opacity = 1.0

        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = NSValue(caTransform3D: fromTransform)
        move.toValue = NSValue(caTransform3D: CATransform3DIdentity)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0

        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = Motion.duration
        group.timingFunction = Motion.timing
        // No removal/cleanup needed: animations are non-additive and the layer's
        // model values are already at their final identity/1.0 state, so when the
        // animation finishes the wrapper simply rests where it already is. Safe
        // under rapid splits — a later rebuild() nukes & rebuilds the subtree,
        // discarding any in-flight animation with its (removed) wrapper.
        layer.add(group, forKey: "halite.split-in")
    }

    // MARK: - Border 색 갱신

    private func updateBorderColors() {
        func walk(_ view: NSView) {
            if let wrapper = view as? PaneLeafWrapper {
                wrapper.isActive = (wrapper.leaf === activeLeaf)
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(self)
    }

    /// node가 leaf면 그대로, split이면 첫 leaf까지 내려감.
    private func firstLeaf(of node: PaneNode) -> PaneNode {
        switch node.kind {
        case .leaf: return node
        case .split(_, let a, _, _): return firstLeaf(of: a)
        }
    }
}

/// Leaf wrapper view — 1px border로 active 표시.
private final class PaneLeafWrapper: NSView {
    let leaf: PaneNode
    weak var owner: PaneTreeView?
    var isActive: Bool = false {
        didSet { needsDisplay = true }
    }

    init(leaf: PaneNode, owner: PaneTreeView) {
        self.leaf = leaf
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        (isActive ? NSColor.systemBlue.withAlphaComponent(0.6) : NSColor.clear).setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        owner?.setActive(leaf)
        super.mouseDown(with: event)
    }
}

/// Split container — 두 sub-area + 가운데 divider. divider drag로 ratio 조정.
private final class SplitContainer: NSView {
    let node: PaneNode
    weak var owner: PaneTreeView?
    let firstContainer = NSView()
    let secondContainer = NSView()
    private let divider = DividerView()
    private let dividerThickness: CGFloat = 4

    init(node: PaneNode, owner: PaneTreeView) {
        self.node = node
        self.owner = owner
        super.init(frame: .zero)
        for v in [firstContainer, secondContainer, divider] {
            v.wantsLayer = true
            addSubview(v)
        }
        divider.onDrag = { [weak self] delta in self?.applyDrag(delta) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard case .split(let dir, _, _, let ratio) = node.kind else { return }
        switch dir {
        case .horizontal:  // 좌우 분할
            let total = bounds.width
            let firstW = max(0, total * ratio - dividerThickness / 2)
            let secondW = max(0, total - firstW - dividerThickness)
            firstContainer.frame = NSRect(x: 0, y: 0, width: firstW, height: bounds.height)
            divider.frame = NSRect(x: firstW, y: 0, width: dividerThickness, height: bounds.height)
            secondContainer.frame = NSRect(
                x: firstW + dividerThickness, y: 0,
                width: secondW, height: bounds.height
            )
            divider.orientation = .vertical
        case .vertical:    // 위아래 분할
            let total = bounds.height
            let secondH = max(0, total * (1 - ratio) - dividerThickness / 2)
            let firstH = max(0, total - secondH - dividerThickness)
            // bottom-up 좌표계 — first가 위, second가 아래로 보이도록.
            secondContainer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: secondH)
            divider.frame = NSRect(x: 0, y: secondH, width: bounds.width, height: dividerThickness)
            firstContainer.frame = NSRect(
                x: 0, y: secondH + dividerThickness,
                width: bounds.width, height: firstH
            )
            divider.orientation = .horizontal
        }
    }

    private func applyDrag(_ delta: CGFloat) {
        guard case .split(let dir, let a, let b, let ratio) = node.kind else { return }
        let total: CGFloat
        let deltaRatio: CGFloat
        switch dir {
        case .horizontal:
            total = bounds.width
            deltaRatio = delta / max(total, 1)
        case .vertical:
            total = bounds.height
            deltaRatio = -delta / max(total, 1)  // bottom-up coord
        }
        let newRatio = min(0.95, max(0.05, ratio + deltaRatio))
        node.kind = .split(direction: dir, first: a, second: b, ratio: newRatio)
        needsLayout = true
    }
}

/// 드래그 가능한 divider.
private final class DividerView: NSView {
    enum Orientation { case horizontal, vertical }
    var orientation: Orientation = .vertical {
        didSet { updateCursor() }
    }
    var onDrag: ((CGFloat) -> Void)?
    private var dragStart: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.gridColor.withAlphaComponent(0.4).cgColor
        updateCursor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateCursor() {
        // 트래킹 영역 + cursor — 마우스 hover 시 적절한 drag cursor.
        let opts: NSTrackingArea.Options = [
            .activeInActiveApp, .inVisibleRect, .cursorUpdate,
        ]
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func cursorUpdate(with event: NSEvent) {
        switch orientation {
        case .vertical: NSCursor.resizeLeftRight.set()
        case .horizontal: NSCursor.resizeUpDown.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = window?.mouseLocationOutsideOfEventStream
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart,
              let now = window?.mouseLocationOutsideOfEventStream
        else { return }
        let delta: CGFloat
        switch orientation {
        case .vertical: delta = now.x - start.x
        case .horizontal: delta = now.y - start.y
        }
        dragStart = now
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }
}
