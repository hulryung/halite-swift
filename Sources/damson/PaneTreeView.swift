import AppKit
import DamsonTerminal

/// Pane focus move direction (Cmd+Opt+arrow).
enum PaneFocusDirection {
    case left, right, up, down
}

/// NSView that lays out the PaneNode tree on screen. Divider drag adjusts the ratio,
/// clicking a leaf selects the active pane. Cmd+D / Cmd+Shift+D split, Cmd+W closes the active pane.
final class PaneTreeView: NSView {
    private(set) var root: PaneNode
    private(set) var activeLeaf: PaneNode
    /// True while `rebuild()` re-creates the view tree — onFocus callbacks from
    /// surfaces being re-added are ignored so they don't clobber the active pane.
    private var rebuilding = false

    /// Called when the last leaf is closed (the host — the tab controller — closes the tab/window).
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

    /// Direction (the outer edge) the closing pane slides toward as it disappears. self is non-flipped (y up).
    private enum ClosingEdge {
        case left, right, top, bottom

        /// (dx, dy) translation equal to a nudge of `size` (the closing frame's width/height) times 0.06.
        /// Since self is y-up, bottom is -y and top is +y.
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

    /// Session restore — construct from an already-built PaneNode tree. active is the first leaf.
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
        // A split always inherits the current pane's working directory (shell-integration
        // OSC 7 report → falling back to the cwd at spawn time), since opening a pane
        // alongside within the same project is the common case.
        var config = DamsonConfig.fromUserDefaults()
        if let cwd = activeSession.currentDirectory { config.cwd = cwd }
        let newSession = DamsonSession(config: config)
        let newLeaf = PaneNode.leaf(newSession)
        let oldKind = activeLeaf.kind
        // Replace activeLeaf's kind with a split. The activeLeaf instance stays the same (preserving the parent link).
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

    /// Closes the leaf holding a session when that session ends (shell exit). The exit
    /// callback may arrive on another thread, so ensure this is invoked on main.
    func closeSession(_ session: DamsonSession) {
        guard let leaf = leafNode(for: session, in: root) else { return }
        closeLeaf(leaf)
    }

    /// Closes the given leaf (fires onAllPanesClosed if it was the last pane). Shared by
    /// closeActive and shell exit.
    func closeLeaf(_ leaf: PaneNode) {
        guard case .leaf(let s, _) = leaf.kind else { return }

        // --- Compute the animation intent (before mutating the tree). On disabled/snapshot-failure, .none → instant path. ---
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
            case .horizontal: edge = isFirst ? .left : .right   // first=left, second=right
            case .vertical:   edge = isFirst ? .top  : .bottom  // first=top, second=bottom
            }
            animation = .close(snapshot: snap, closingFrame: closingFrame, edge: edge)
        }

        // Terminate the session (already dead on a shell exit, but idempotent).
        s.terminate()
        // The parent's other child is promoted into the parent's slot.
        guard let parent = leaf.parent,
              case .split(_, let first, let second, _) = parent.kind
        else {
            // Closed the root leaf — shut everything down.
            onAllPanesClosed?()
            return
        }
        let sibling = (first === leaf) ? second : first
        parent.kind = sibling.kind
        // If the sibling was a split, update its children's parent links.
        if case .split(_, let a, let b, _) = parent.kind {
            a.parent = parent
            b.parent = parent
        }
        // Set the new active to the first leaf of the promoted sub-tree.
        activeLeaf = firstLeaf(of: parent)
        rebuild(animation: animation)
    }

    /// Find the leaf node in the tree holding the given session (by === identity).
    private func leafNode(for session: DamsonSession, in node: PaneNode) -> PaneNode? {
        switch node.kind {
        case .leaf(let s, _):
            return s === session ? node : nil
        case .split(_, let a, let b, _):
            return leafNode(for: session, in: a) ?? leafNode(for: session, in: b)
        }
    }

    /// Externally invoked to change the active pane (e.g. on a mouse click).
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

    /// ⌘⇧+click — swap the *positions* of the clicked pane and the current active pane.
    /// Only the two leaf nodes' payloads (session+surface) are exchanged, so the tree
    /// shape/parent links/ratio stay intact. The active session moves to the new position
    /// and focus follows that session.
    func swapActive(with target: PaneNode) {
        guard target !== activeLeaf, target.isLeaf, activeLeaf.isLeaf else { return }

        // Before the swap, capture each pane's current position + snapshot (including the
        // Metal surface). Since rebuild places the content into the new slots instantly,
        // we lay these snapshots over the old positions and slide them to each other's
        // position to create the 'two panes trading places' motion.
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
        // The active session now lives in the target node, so move active there for focus to follow.
        activeLeaf = target
        rebuild(animation: animation)
    }

    /// Cmd+Opt+arrow — move focus to the nearest adjacent pane in the given direction,
    /// relative to the current active pane's on-screen position.
    func moveFocus(_ dir: PaneFocusDirection) {
        if let target = directionalNeighbor(dir) { setActive(target) }
    }

    /// damson-cli `resize-pane` — nudge the split divider that governs the active pane
    /// toward `dir` by `fraction` of the relevant axis (one nudge per call). Walks up from
    /// the active leaf to the nearest ancestor split whose axis matches the direction
    /// (horizontal split ↔ left/right, vertical split ↔ up/down), then shifts its ratio
    /// the same way SplitContainer.applyDrag does. Returns false if there's no such split.
    @discardableResult
    func resizeActiveDivider(_ dir: PaneFocusDirection, fraction: CGFloat) -> Bool {
        let wantHorizontal = (dir == .left || dir == .right)
        // Find the nearest ancestor split on the matching axis, and whether the active
        // pane lives in its `first` (left/top) subtree — that decides the ratio sign.
        var child: PaneNode = activeLeaf
        var node: PaneNode? = activeLeaf.parent
        while let parent = node {
            if case .split(let sdir, let first, let second, let ratio) = parent.kind {
                let axisMatches = (sdir == .horizontal) == wantHorizontal
                if axisMatches {
                    let inFirst = containsNode(child, in: first)
                    // Moving the divider "right"/"down" grows the first (left/top) pane.
                    // Mirror applyDrag's coordinate handling: vertical splits are bottom-up.
                    var delta: CGFloat
                    switch dir {
                    case .right, .down: delta = fraction
                    case .left, .up:    delta = -fraction
                    }
                    // If the active pane is the second child, a positive nudge in its own
                    // direction should grow IT, so flip the sign relative to the first pane.
                    if !inFirst { delta = -delta }
                    let newRatio = min(0.95, max(0.05, ratio + delta))
                    parent.kind = .split(direction: sdir, first: first, second: second, ratio: newRatio)
                    needsLayout = true
                    return true
                }
            }
            child = parent
            node = parent.parent
        }
        return false
    }

    /// True if `target` is `subtree` or lives anywhere inside it.
    private func containsNode(_ target: PaneNode, in subtree: PaneNode) -> Bool {
        if subtree === target { return true }
        if case .split(_, let a, let b, _) = subtree.kind {
            return containsNode(target, in: a) || containsNode(target, in: b)
        }
        return false
    }

    /// Leaf sessions in left-to-right / top-to-bottom traversal order, paired with whether each is active.
    /// For damson-cli `list-panes`.
    func paneSessionsInOrder() -> [(session: DamsonSession, active: Bool)] {
        var out: [(DamsonSession, Bool)] = []
        func walk(_ node: PaneNode) {
            switch node.kind {
            case .leaf(let s, _):
                out.append((s, node === activeLeaf))
            case .split(_, let a, let b, _):
                walk(a); walk(b)
            }
        }
        walk(root)
        return out
    }

    /// Cmd+Shift+arrow — swap *positions* with the nearest adjacent pane in the given direction.
    func swapDirectional(_ dir: PaneFocusDirection) {
        if let target = directionalNeighbor(dir) { swapActive(with: target) }
    }

    /// Find the leaf closest on screen in the `dir` direction relative to the active pane.
    /// Uses the leaf wrappers' frames in self's coordinate space. (Shared by focus move/swap.)
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

        // Keep only candidates matching the direction (clearly offset along that axis), then pick the smallest center distance.
        var best: PaneLeafWrapper?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for w in wrappers where w !== current {
            let f = w.convert(w.bounds, to: self)
            let mid = NSPoint(x: f.midX, y: f.midY)
            let dx = mid.x - curMid.x
            let dy = mid.y - curMid.y
            // self is non-flipped (y up). up = increasing y, down = decreasing y.
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

    // MARK: - Tree → NSView rebuild

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
        // The live hierarchy was rebuilt to its final state above (the sibling snaps to full). Now handle the per-intent overlays.
        switch animation {
        case .none:
            break

        case .split(let newLeaf):
            // (Task 3) Motion of the new pane sliding in from the divider edge — derive the
            // direction from the parent split, then make the 2-arg call.
            guard let parent = newLeaf.parent,
                  case .split(let dir, _, _, _) = parent.kind
            else { break }
            animateSplitIn(newLeaf: newLeaf, direction: dir)

        case .close(let snapshot, let closingFrame, let edge):
            // (Task 5) Motion of the closed pane's snapshot disappearing — nudging from its
            // old frame toward the outer edge while fading out — extracted into a helper
            // (symmetric with animateSplitIn).
            animateCloseOut(snapshot: snapshot, closingFrame: closingFrame, edge: edge)

        case .swap(let snapA, let frameA, let snapB, let frameB):
            // The two pane snapshots cross-slide in straight lines into each other's slots.
            animateSwap(snapA: snapA, frameA: frameA, snapB: snapB, frameB: frameB)
        }
    }

    private func addSubviewsForNode(_ node: PaneNode, into container: NSView) {
        switch node.kind {
        case .leaf(let session, let surface):
            // leaf container — wrapper used to show the border. Fills via frame + autoresizing.
            let wrapper = PaneLeafWrapper(leaf: node, owner: self)
            wrapper.translatesAutoresizingMaskIntoConstraints = true
            wrapper.autoresizingMask = [.width, .height]
            wrapper.frame = container.bounds
            container.addSubview(wrapper)
            // The surface fills the wrapper completely — the active indicator (dim/border)
            // is drawn by an overlay layer on top, so no inset is needed. Adjacent panes
            // butt together, so the only visible seam is the 1px divider line.
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
            // split — two sub-areas + divider. SplitContainer.layout() computes the frames
            // (direction/ratio are read directly from node.kind, so no binding is needed here).
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

        // The overlay is a sublayer of self.layer, so rebuild()'s subviews teardown doesn't
        // touch it → even under rapid/nested rebuilds it isn't stranded and is only removed in asyncAfter.
        let overlay = Motion.overlay(image: snapshot, frame: closingFrame, in: self)
        let off = edge.offset(in: closingFrame.size)
        let fromPos = overlay.position
        let toPos = CGPoint(x: fromPos.x + off.width, y: fromPos.y + off.height)

        // Same explicit CABasicAnimation idiom as closeTab: on a vanilla CALayer with no
        // delegate, a bare model assignment triggers CA's default implicit animation — so we don't touch the model before/after add().
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

        // We don't write the model values separately. fillMode = .forwards pins the
        // slid/faded final state from completion until removal, so no model update is needed.
        overlay.add(group, forKey: "damson.pane-close")

        // Remove the overlay after the animation. Each close captures only its own overlay,
        // so rapid successive closes are safe with no shared state.
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.duration) {
            overlay.removeFromSuperlayer()
        }
    }

    /// Cross-slide swap: the A snapshot moves in a straight line frameA→frameB and the B
    /// snapshot frameB→frameA. If the two panes differ in size, bounds.size is interpolated
    /// along with position (content stretches via `.resize` gravity), so on arrival it
    /// matches the live content size exactly → the overlay removal is seamless. Same overlay
    /// idiom as close (explicit CABasicAnimation + fillMode forwards + asyncAfter removal).
    private func animateSwap(snapA: NSImage, frameA: NSRect, snapB: NSImage, frameB: NSRect) {
        // Settle the live content rebuild just placed into its final position/size (before the snapshot covers it).
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

    /// Animate the overlay layer's position+size together from `from`→`to` (frames in self's coordinates).
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

    // MARK: - Border color update

    private func updateBorderColors() {
        func walk(_ view: NSView) {
            if let wrapper = view as? PaneLeafWrapper {
                wrapper.isActive = (wrapper.leaf === activeLeaf)
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(self)
    }

    /// Re-apply to every wrapper when the active-pane indicator setting changes (active state unchanged).
    func refreshIndicators() {
        func walk(_ view: NSView) {
            (view as? PaneLeafWrapper)?.applyIndicator()
            for sub in view.subviews { walk(sub) }
        }
        walk(self)
    }

    /// If node is a leaf, return it; if a split, descend to the first leaf.
    private func firstLeaf(of node: PaneNode) -> PaneNode {
        switch node.kind {
        case .leaf: return node
        case .split(_, let a, _, _): return firstLeaf(of: a)
        }
    }
}

/// Leaf wrapper view — shows the active pane in the configured style (dim / border).
private final class PaneLeafWrapper: NSView {
    let leaf: PaneNode
    weak var owner: PaneTreeView?
    /// Overlays that sit above the terminal's Metal layer (with a high zPosition).
    /// dimLayer = inactive-pane scrim, borderLayer = active-pane border.
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

        // Focus-follows-mouse: hover over a pane to activate it. The terminal
        // surface sits on top with its own tracking areas, but tracking areas are
        // per-view and independent, so this one still fires when the cursor crosses
        // into the wrapper. `.inVisibleRect` keeps it sized across splits/resizes.
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self, userInfo: nil
        )
        addTrackingArea(tracking)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// When the cursor enters this pane (setting on + key window), make it the active
    /// pane — same path as a click. While the mouse button is held and dragged into
    /// another pane (drag-selection/divider), events are captured by the originating
    /// view so no enter arrives and it doesn't interfere.
    override func mouseEntered(with event: NSEvent) {
        guard FocusFollowsMouse.enabled,
              window?.isKeyWindow == true,
              owner?.activeLeaf !== leaf
        else { return }
        owner?.setActive(leaf)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.frame = bounds
        borderLayer.frame = bounds
        CATransaction.commit()
    }

    /// Re-read the settings and refresh the indicator (on active change or settings change).
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

    /// A subtle border color shifted slightly from the background (dark theme → a bit lighter, light theme → a bit darker).
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
            // ⌘⇧+click — swap this pane's position with the active pane. Don't forward to the surface.
            owner?.swapActive(with: leaf)
            return
        }
        owner?.setActive(leaf)
        super.mouseDown(with: event)
    }
}

/// Split container — two sub-areas + a divider in the middle. Divider drag adjusts the ratio.
private final class SplitContainer: NSView {
    let node: PaneNode
    weak var owner: PaneTreeView?
    let firstContainer = NSView()
    let secondContainer = NSView()
    private let divider = DividerView()
    /// Width of the easy-to-grab hit zone. The divider is this wide but draws only a 1px line in the center.
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
        addSubview(divider)   // place above the panels to occupy the drag zone at the boundary
        divider.onDrag = { [weak self] delta in self?.applyDrag(delta) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard case .split(let dir, _, _, let ratio) = node.kind else { return }
        // Butt the panels together (no gap) and overlay the divider on the boundary → only
        // a thin 1px line shows, while the wide hit zone keeps dragging easy.
        switch dir {
        case .horizontal:  // left/right split
            let total = bounds.width
            let firstW = (total * ratio).rounded()
            firstContainer.frame = NSRect(x: 0, y: 0, width: firstW, height: bounds.height)
            secondContainer.frame = NSRect(x: firstW, y: 0, width: total - firstW, height: bounds.height)
            divider.frame = NSRect(x: firstW - dividerDrag / 2, y: 0, width: dividerDrag, height: bounds.height)
            divider.orientation = .vertical
        case .vertical:    // top/bottom split
            let total = bounds.height
            let secondH = (total * (1 - ratio)).rounded()
            let firstH = total - secondH
            // bottom-up coordinate system — so first appears on top and second on the bottom.
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

/// Draggable divider.
private final class DividerView: NSView {
    enum Orientation { case horizontal, vertical }
    var orientation: Orientation = .vertical {
        didSet { updateCursor(); needsDisplay = true }
    }
    var onDrag: ((CGFloat) -> Void)?
    private var dragStart: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true   // background is clear — the drag zone is wide but only a 1px line is drawn in the center.
        updateCursor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Draw only a thin 1px separator line in the center of the wide hit zone (thin and subtle).
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
        // Tracking area + cursor — show the appropriate drag cursor on mouse hover.
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
