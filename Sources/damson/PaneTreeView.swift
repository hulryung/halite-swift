import AppKit
import DamsonTerminal

/// Pane focus 이동 방향 (Cmd+Opt+화살표).
enum PaneFocusDirection {
    case left, right, up, down
}

/// PaneNode 트리를 화면에 배치하는 NSView. divider drag로 ratio 조정 + leaf 클릭으로
/// active pane 선택. Cmd+D / Cmd+Shift+D 로 split, Cmd+W 로 active pane 닫기.
final class PaneTreeView: NSView {
    private(set) var root: PaneNode
    private(set) var activeLeaf: PaneNode
    /// True while `rebuild()` re-creates the view tree — onFocus callbacks from
    /// surfaces being re-added are ignored so they don't clobber the active pane.
    private var rebuilding = false

    /// 마지막 leaf가 닫혔을 때 호출 (호스트 — 탭 컨트롤러 — 가 탭/윈도우를 닫음).
    var onAllPanesClosed: (() -> Void)?

    /// Pane lifecycle animation intent threaded through `rebuild`. `.none` is the
    /// instant/legacy path; `.split` animates the newly-created pane in from the
    /// divider edge; `.close` slides the closing pane's snapshot out to its outer edge.
    private enum PaneAnimation {
        case none
        /// After rebuild, find the wrapper whose leaf === `newLeaf` and animate it in.
        case split(newLeaf: PaneNode)
        case close(snapshot: NSImage, closingFrame: NSRect, edge: ClosingEdge)
        /// Cross-slide swap: each pane's snapshot glides from its old slot to the
        /// other's. Frames are in self coords; differing sizes are interpolated too.
        case swap(snapA: NSImage, frameA: NSRect, snapB: NSImage, frameB: NSRect)
    }

    /// 닫히는 pane이 슬라이드해 사라질 방향(바깥 edge). self는 non-flipped(y up).
    private enum ClosingEdge {
        case left, right, top, bottom

        /// `size`(닫히는 frame의 가로/세로)에 0.06을 곱한 nudge 만큼의 (dx, dy) translation.
        /// self가 y-up이므로 bottom은 -y, top은 +y.
        func offset(in size: CGSize) -> CGSize {
            let nudgeX = size.width * 0.06
            let nudgeY = size.height * 0.06
            switch self {
            case .left:   return CGSize(width: -nudgeX, height: 0)
            case .right:  return CGSize(width:  nudgeX, height: 0)
            case .top:    return CGSize(width: 0, height:  nudgeY)
            case .bottom: return CGSize(width: 0, height: -nudgeY)
            }
        }
    }

    init(rootSession: DamsonSession) {
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
        guard case .leaf(let activeSession, _) = activeLeaf.kind else { return }
        // split은 항상 현재 pane의 작업 디렉토리를 상속(셸 통합 OSC 7 보고 → 없으면
        // spawn 당시 cwd). 같은 프로젝트 안에서 옆에 pane을 여는 게 일반적이라.
        var config = DamsonConfig.fromUserDefaults()
        if let cwd = activeSession.currentDirectory { config.cwd = cwd }
        let newSession = DamsonSession(config: config)
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

    func closeActive() { closeLeaf(activeLeaf) }

    /// 세션이 종료(셸 exit)됐을 때 그 세션을 가진 leaf를 닫는다. 종료 콜백은 다른
    /// 스레드일 수 있어 main에서 호출되도록 한다.
    func closeSession(_ session: DamsonSession) {
        guard let leaf = leafNode(for: session, in: root) else { return }
        closeLeaf(leaf)
    }

    /// 지정한 leaf를 닫는다 (마지막 pane이면 onAllPanesClosed). closeActive와 셸
    /// exit가 공유한다.
    func closeLeaf(_ leaf: PaneNode) {
        guard case .leaf(let s, _) = leaf.kind else { return }

        // --- 애니메이션 의도 계산 (트리 변경 전에). 비활성/스냅샷 실패 시 .none로 즉시 경로. ---
        var animation: PaneAnimation = .none
        if Motion.enabled,
           let parent = leaf.parent,
           case .split(let dir, let first, _, _) = parent.kind,
           let wrapper = findWrapper(for: leaf, in: self),
           let snap = Motion.snapshot(of: wrapper) {
            let closingFrame = wrapper.convert(wrapper.bounds, to: self)
            let isFirst = (first === leaf)
            let edge: ClosingEdge
            switch dir {
            case .horizontal: edge = isFirst ? .left : .right   // first=좌, second=우
            case .vertical:   edge = isFirst ? .top  : .bottom  // first=위, second=아래
            }
            animation = .close(snapshot: snap, closingFrame: closingFrame, edge: edge)
        }

        // session terminate (셸 exit면 이미 죽었지만 idempotent).
        s.terminate()
        // 부모의 다른 child가 그 부모 자리로 promote.
        guard let parent = leaf.parent,
              case .split(_, let first, let second, _) = parent.kind
        else {
            // root leaf 닫은 경우 — 전체 종료.
            onAllPanesClosed?()
            return
        }
        let sibling = (first === leaf) ? second : first
        parent.kind = sibling.kind
        // sibling이 split이었으면 그 자식들의 parent를 갱신.
        if case .split(_, let a, let b, _) = parent.kind {
            a.parent = parent
            b.parent = parent
        }
        // 새 active를 promote된 sub-tree의 첫 leaf로 설정.
        activeLeaf = firstLeaf(of: parent)
        rebuild(animation: animation)
    }

    /// 트리에서 주어진 세션을 가진 leaf 노드를 찾는다 (=== 식별).
    private func leafNode(for session: DamsonSession, in node: PaneNode) -> PaneNode? {
        switch node.kind {
        case .leaf(let s, _):
            return s === session ? node : nil
        case .split(_, let a, let b, _):
            return leafNode(for: session, in: a) ?? leafNode(for: session, in: b)
        }
    }

    /// 마우스 클릭 등으로 외부에서 active pane 변경 호출.
    func setActive(_ leaf: PaneNode) {
        guard case .leaf(_, let surface) = leaf.kind else { return }
        let changed = activeLeaf !== leaf
        activeLeaf = leaf
        updateBorderColors()
        // Only re-grab first responder on an actual change — onFocus→setActive
        // calls back in here when a pane is clicked, so re-asserting would loop.
        if changed, window?.firstResponder !== surface {
            window?.makeFirstResponder(surface)
        }
    }

    /// ⌘⇧+클릭 — 클릭한 pane과 현재 active pane의 *위치*를 맞바꾼다. 두 leaf 노드의
    /// payload(session+surface)만 교환하므로 트리 형태/parent 링크/ratio는 그대로 유지된다.
    /// active 세션이 새 위치로 옮겨가고 focus도 그 세션을 따라간다.
    func swapActive(with target: PaneNode) {
        guard target !== activeLeaf, target.isLeaf, activeLeaf.isLeaf else { return }

        // 스왑 전, 두 pane의 현재 위치 + 스냅샷(Metal surface 포함)을 잡아둔다. rebuild가
        // 콘텐츠를 즉시 새 슬롯에 배치하므로, 이 스냅샷들을 옛 위치에 얹고 서로의 위치로
        // 미끄러뜨려 '두 pane이 자리를 바꾸는' 모션을 만든다.
        var animation: PaneAnimation = .none
        if Motion.enabled,
           let wrapperA = findWrapper(for: activeLeaf, in: self),
           let wrapperB = findWrapper(for: target, in: self),
           let snapA = Motion.snapshot(of: wrapperA),
           let snapB = Motion.snapshot(of: wrapperB) {
            animation = .swap(
                snapA: snapA, frameA: wrapperA.convert(wrapperA.bounds, to: self),
                snapB: snapB, frameB: wrapperB.convert(wrapperB.bounds, to: self)
            )
        }

        let activeKind = activeLeaf.kind
        activeLeaf.kind = target.kind
        target.kind = activeKind
        // active 세션이 이제 target 노드에 있으므로 focus가 따라가도록 active를 옮긴다.
        activeLeaf = target
        rebuild(animation: animation)
    }

    /// Cmd+Opt+화살표 — 현재 active pane의 화면 위치 기준으로 방향상 가장 가까운
    /// 인접 pane으로 focus 이동.
    func moveFocus(_ dir: PaneFocusDirection) {
        if let target = directionalNeighbor(dir) { setActive(target) }
    }

    /// Cmd+Shift+화살표 — 방향상 가장 가까운 인접 pane과 *위치*를 맞바꾼다.
    func swapDirectional(_ dir: PaneFocusDirection) {
        if let target = directionalNeighbor(dir) { swapActive(with: target) }
    }

    /// active pane 기준으로 `dir` 방향에 화면상 가장 가까운 leaf를 찾는다.
    /// leaf wrapper들의 self 좌표계 frame을 사용. (focus 이동/스왑 공용.)
    private func directionalNeighbor(_ dir: PaneFocusDirection) -> PaneNode? {
        var wrappers: [PaneLeafWrapper] = []
        func collect(_ v: NSView) {
            if let w = v as? PaneLeafWrapper { wrappers.append(w) }
            for sub in v.subviews { collect(sub) }
        }
        collect(self)
        guard wrappers.count >= 2,
              let current = wrappers.first(where: { $0.leaf === activeLeaf })
        else { return nil }

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
        return best?.leaf
    }

    // MARK: - Tree → NSView 재구성

    private func rebuild(animation: PaneAnimation = .none) {
        // Re-adding surfaces fires their viewDidMoveToWindow → makeFirstResponder →
        // onFocus, which would set the active pane to a stale node mid-rebuild.
        // Suppress onFocus during the rebuild; we set the correct active explicitly.
        rebuilding = true
        defer { rebuilding = false }
        for sub in subviews { sub.removeFromSuperview() }
        addSubviewsForNode(root, into: self)
        updateBorderColors()
        if case .leaf(_, let surface) = activeLeaf.kind {
            window?.makeFirstResponder(surface)
        }
        needsLayout = true
        // 라이브 계층은 위에서 최종 상태로 재구성됨 (sibling이 full로 snap). 이제 의도별 오버레이 처리.
        switch animation {
        case .none:
            break

        case .split(let newLeaf):
            // (Task 3) 새 pane이 divider edge에서 밀어내려 나타나는 모션 — 부모 split에서
            // 방향 도출 후 2-arg 호출.
            guard let parent = newLeaf.parent,
                  case .split(let dir, _, _, _) = parent.kind
            else { break }
            animateSplitIn(newLeaf: newLeaf, direction: dir)

        case .close(let snapshot, let closingFrame, let edge):
            // (Task 5) 닫힌 pane 스냅샷이 옛 frame에서 바깥 edge로 nudge + fade out 되며
            // 사라지는 모션 — 헬퍼로 추출 (animateSplitIn과 대칭).
            animateCloseOut(snapshot: snapshot, closingFrame: closingFrame, edge: edge)

        case .swap(let snapA, let frameA, let snapB, let frameB):
            // 두 pane 스냅샷이 서로의 슬롯으로 직선 크로스 슬라이드.
            animateSwap(snapA: snapA, frameA: frameA, snapB: snapB, frameB: frameB)
        }
    }

    private func addSubviewsForNode(_ node: PaneNode, into container: NSView) {
        switch node.kind {
        case .leaf(let session, let surface):
            // leaf 컨테이너 — border 표시용 wrapper. frame + autoresizing 으로 fill.
            let wrapper = PaneLeafWrapper(leaf: node, owner: self)
            wrapper.translatesAutoresizingMaskIntoConstraints = true
            wrapper.autoresizingMask = [.width, .height]
            wrapper.frame = container.bounds
            container.addSubview(wrapper)
            // surface가 wrapper를 꽉 채움 — 활성 표시(dim/테두리)는 위에 얹은
            // overlay 레이어로 그리므로 inset 불필요. 인접 pane끼리 맞붙어 seam은
            // divider 1px 선만 보인다.
            surface.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(surface)
            NSLayoutConstraint.activate([
                surface.topAnchor.constraint(equalTo: wrapper.topAnchor),
                surface.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
                surface.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            ])
            // Clicking a pane's content makes its surface first responder; mirror
            // that into the active-pane state (and indicator) since the surface now
            // fills the wrapper, so the wrapper no longer gets the click itself.
            surface.onFocus = { [weak self, weak node] in
                guard let self, let node, !self.rebuilding else { return }
                self.setActive(node)
            }
            // Shell exited (e.g. `exit`) → close this pane (collapses the split, or
            // closes the tab/window if it was the last). Fired on a PTY thread, so
            // hop to main. Found by session identity so a later split/rebuild that
            // moved the node doesn't matter.
            session.onExit = { [weak self, weak session] _ in
                guard let session else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.closeSession(session)
                }
            }

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
        // CABasicAnimation in DamsonTerminalView). The model values are at their
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
        layer.add(group, forKey: "damson.split-in")
    }

    /// Animate the closing pane "sliding out toward its outer edge": a bitmap
    /// snapshot of the closed pane sits at its old `closingFrame` and slides a small
    /// nudge toward `edge` (the outer edge, away from the divider) while fading
    /// α 1→0, then removes itself. The live sibling has already snapped to full size
    /// underneath. Mirrors `animateSplitIn` (a single call from `rebuild`'s switch).
    private func animateCloseOut(snapshot: NSImage, closingFrame: NSRect, edge: ClosingEdge) {
        // Unlike split, the overlay's frame is the precomputed `closingFrame`, so
        // this layout pass is NOT for sizing the overlay — it settles the live
        // sibling underneath (just added by rebuild) into its full-size final state
        // before the snapshot covers it, so the snap is complete on frame 0.
        layoutSubtreeIfNeeded()

        // 오버레이는 self.layer의 sublayer라 rebuild()의 subviews teardown이 건드리지 않음 →
        // 빠른/중첩 rebuild에도 stranding 없이 asyncAfter에서만 제거됨.
        let overlay = Motion.overlay(image: snapshot, frame: closingFrame, in: self)
        let off = edge.offset(in: closingFrame.size)
        let fromPos = overlay.position
        let toPos = CGPoint(x: fromPos.x + off.width, y: fromPos.y + off.height)

        // closeTab과 같은 명시적 CABasicAnimation 관용구: delegate 없는 vanilla CALayer라
        // bare 모델 대입은 CA의 기본 암시적 애니메이션을 유발 — add() 전후로 모델을 건드리지 않는다.
        let slide = CABasicAnimation(keyPath: "position")
        slide.fromValue = NSValue(point: fromPos)
        slide.toValue = NSValue(point: toPos)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0

        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = Motion.duration
        group.timingFunction = Motion.timing
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards

        // 모델값을 따로 쓰지 않는다. fillMode = .forwards 가 종료~제거 사이 동안
        // 슬라이드/페이드된 최종 상태를 그대로 고정하므로 모델 갱신이 불필요하다.
        overlay.add(group, forKey: "damson.pane-close")

        // 애니메이션 후 오버레이 제거. 각 close는 자기 오버레이만 캡처하므로
        // 빠른 연속 닫기에도 공유 상태 없이 안전.
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.duration) {
            overlay.removeFromSuperlayer()
        }
    }

    /// 크로스 슬라이드 스왑: A 스냅샷은 frameA→frameB, B 스냅샷은 frameB→frameA 로 직선
    /// 이동. 두 pane 크기가 다르면 position과 함께 bounds.size 도 보간하므로(콘텐츠는
    /// `.resize` gravity로 늘어남) 도착 시 라이브 콘텐츠 크기와 정확히 맞아 떨어진다 →
    /// 오버레이 제거가 매끄럽다. close와 같은 오버레이 관용구(명시 CABasicAnimation +
    /// fillMode forwards + asyncAfter 제거).
    private func animateSwap(snapA: NSImage, frameA: NSRect, snapB: NSImage, frameB: NSRect) {
        // rebuild가 막 배치한 라이브 콘텐츠를 최종 위치/크기로 settle (스냅샷이 덮기 전에).
        layoutSubtreeIfNeeded()
        let overlayA = Motion.overlay(image: snapA, frame: frameA, in: self)
        let overlayB = Motion.overlay(image: snapB, frame: frameB, in: self)
        slideOverlay(overlayA, from: frameA, to: frameB, key: "damson.swap-a")
        slideOverlay(overlayB, from: frameB, to: frameA, key: "damson.swap-b")
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.duration) {
            overlayA.removeFromSuperlayer()
            overlayB.removeFromSuperlayer()
        }
    }

    /// 오버레이 레이어를 `from`→`to`(self 좌표 frame)로 position+size 동시 애니메이트.
    private func slideOverlay(_ layer: CALayer, from: NSRect, to: NSRect, key: String) {
        let pos = CABasicAnimation(keyPath: "position")
        pos.fromValue = NSValue(point: CGPoint(x: from.midX, y: from.midY))
        pos.toValue = NSValue(point: CGPoint(x: to.midX, y: to.midY))

        let size = CABasicAnimation(keyPath: "bounds.size")
        size.fromValue = NSValue(size: from.size)
        size.toValue = NSValue(size: to.size)

        let group = CAAnimationGroup()
        group.animations = [pos, size]
        group.duration = Motion.duration
        group.timingFunction = Motion.timing
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        layer.add(group, forKey: key)
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

    /// 활성 pane 표시 설정이 바뀌었을 때 모든 wrapper를 다시 적용 (active 여부는 그대로).
    func refreshIndicators() {
        func walk(_ view: NSView) {
            (view as? PaneLeafWrapper)?.applyIndicator()
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

/// Leaf wrapper view — 활성 pane을 설정된 방식(dim / 테두리)으로 표시.
private final class PaneLeafWrapper: NSView {
    let leaf: PaneNode
    weak var owner: PaneTreeView?
    /// 터미널 Metal 레이어 위에 올라가는 오버레이들 (zPosition 높게).
    /// dimLayer = 비활성 pane scrim, borderLayer = 활성 pane 테두리.
    private let dimLayer = CALayer()
    private let borderLayer = CALayer()
    var isActive: Bool = false {
        didSet { applyIndicator() }
    }

    init(leaf: PaneNode, owner: PaneTreeView) {
        self.leaf = leaf
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.zPosition = 100
        dimLayer.isHidden = true
        borderLayer.zPosition = 101
        borderLayer.borderWidth = 0
        layer?.addSublayer(dimLayer)
        layer?.addSublayer(borderLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.frame = bounds
        borderLayer.frame = bounds
        CATransaction.commit()
    }

    /// 설정값을 다시 읽어 표시를 갱신 (active 변경 또는 설정 변경 시).
    func applyIndicator() {
        let mode = ActivePaneIndicator.current
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.isHidden = !(mode == .dimInactive && !isActive)
        dimLayer.opacity = 0.4
        if isActive, mode == .accentBorder || mode == .subtleBorder {
            let color = (mode == .accentBorder) ? NSColor.controlAccentColor
                                                : Self.subtleBorderColor(leaf: leaf)
            borderLayer.borderColor = color.cgColor
            borderLayer.borderWidth = 1
        } else {
            borderLayer.borderWidth = 0
        }
        CATransaction.commit()
    }

    /// 배경색에서 살짝 이동한 은은한 테두리색 (어두운 테마 → 약간 밝게, 밝은 테마 → 약간 어둡게).
    private static func subtleBorderColor(leaf: PaneNode) -> NSColor {
        guard case .leaf(let session, _) = leaf.kind else { return .clear }
        let bg = (session.config.backgroundColor.usingColorSpace(.sRGB)) ?? .black
        let lum = 0.299 * bg.redComponent + 0.587 * bg.greenComponent + 0.114 * bg.blueComponent
        let target: CGFloat = lum < 0.5 ? 1.0 : 0.0
        let t: CGFloat = 0.25
        func mix(_ a: CGFloat) -> CGFloat { a + (target - a) * t }
        return NSColor(srgbRed: mix(bg.redComponent), green: mix(bg.greenComponent),
                       blue: mix(bg.blueComponent), alpha: 1.0)
    }

    /// While ⌘⇧ is held, claim the click for the wrapper (pane swap) instead of
    /// letting it fall through to the terminal surface underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .isSuperset(of: [.command, .shift]) {
            return self
        }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods == [.command, .shift] {
            // ⌘⇧+클릭 — 이 pane을 active pane과 위치 교환. surface로 전달하지 않는다.
            owner?.swapActive(with: leaf)
            return
        }
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
    /// 드래그를 잡기 쉬운 hit zone 폭. divider는 이만큼 넓지만 가운데 1px 선만 그린다.
    private let dividerDrag: CGFloat = 10

    init(node: PaneNode, owner: PaneTreeView) {
        self.node = node
        self.owner = owner
        super.init(frame: .zero)
        for v in [firstContainer, secondContainer] {
            v.wantsLayer = true
            addSubview(v)
        }
        divider.wantsLayer = true
        addSubview(divider)   // 패널 위에 올려 경계의 drag zone을 차지
        divider.onDrag = { [weak self] delta in self?.applyDrag(delta) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard case .split(let dir, _, _, let ratio) = node.kind else { return }
        // 패널을 맞붙이고(틈 없음) divider를 경계에 겹쳐 둔다 → 가는 1px 선만 보이고
        // 넓은 hit zone으로 드래그는 쉬움.
        switch dir {
        case .horizontal:  // 좌우 분할
            let total = bounds.width
            let firstW = (total * ratio).rounded()
            firstContainer.frame = NSRect(x: 0, y: 0, width: firstW, height: bounds.height)
            secondContainer.frame = NSRect(x: firstW, y: 0, width: total - firstW, height: bounds.height)
            divider.frame = NSRect(x: firstW - dividerDrag / 2, y: 0, width: dividerDrag, height: bounds.height)
            divider.orientation = .vertical
        case .vertical:    // 위아래 분할
            let total = bounds.height
            let secondH = (total * (1 - ratio)).rounded()
            let firstH = total - secondH
            // bottom-up 좌표계 — first가 위, second가 아래로 보이도록.
            secondContainer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: secondH)
            firstContainer.frame = NSRect(x: 0, y: secondH, width: bounds.width, height: firstH)
            divider.frame = NSRect(x: 0, y: secondH - dividerDrag / 2, width: bounds.width, height: dividerDrag)
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
        didSet { updateCursor(); needsDisplay = true }
    }
    var onDrag: ((CGFloat) -> Void)?
    private var dragStart: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true   // 배경은 clear — drag zone은 넓지만 가운데 1px 선만 그림.
        updateCursor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 넓은 hit zone 가운데에 가는 1px 구분선만 그린다 (얇고 은은하게).
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        switch orientation {
        case .vertical:
            NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
        case .horizontal:
            NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()
        }
    }

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
