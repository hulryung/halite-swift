import AppKit

/// Compact 모드 전용 커스텀 탭 바. NSWindow 네이티브 탭을 끄고
/// (tabbingMode = .disallowed) 이걸 contentView 최상단에 배치 → 신호등과
/// 같은 row에 탭이 보임.
///
/// 구조:
///   [80pt 비워둠 (신호등 영역)][탭 1][탭 2]...[탭 N][+ 새 탭][여백]
///
/// Reorder: the bar lives in the window's titlebar region, where the window
/// server normally eats horizontal drags as a window-move before they reach a
/// subview's mouseDragged. Reordering is gated behind Cmd+Shift: holding it
/// "pops out" the tabs and pins the window immovable (isMovable=false), which
/// lets the drag flow through TabButton's responder chain. A local event
/// monitor only watches the chord; the slide animations ride AppKit's normal
/// display cycle.
final class CompactTabBarView: NSView {
    var onTabSelected: ((Int) -> Void)?
    var onTabClosed: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    /// Reorder result after a drag: move the tab from `from` to `to`.
    var onTabReordered: ((Int, Int) -> Void)?
    /// Double-click rename result: set tab `index`'s title to `title` ("" = revert to auto).
    var onTabRenamed: ((Int, String) -> Void)?

    private var tabButtons: [TabButton] = []
    private let newTabButton = NSButton()
    private var selectedIndex: Int = 0

    // Drag-reorder state.
    private var perTab: CGFloat = 100   // current per-tab width (updated in layout)
    private var dragTargetIndex: Int?
    // Reorder mode (Cmd+Shift held). A local event monitor owns the drag so the
    // events never reach the window's titlebar drag machinery.
    private var reorderModeActive = false
    private var draggingIndex: Int?
    private var lastGapTarget: Int?   // insertion slot currently shown, to animate only on change
    private var eventMonitor: Any?
    // The window server handles titlebar drag-to-move from the draggable region,
    // before our monitor sees leftMouseDragged. Pinning isMovable=false for the
    // duration of the chord stops that so the drag events reach us. We capture
    // the prior value and always restore it (release, window change, teardown).
    private var savedIsMovable: Bool?

    // 신호등(닫기/최소화/최대화 버튼) 자리. 전체화면에선 신호등이 숨겨지므로 예약을
    // 없애 탭이 왼쪽 가장자리부터 시작하게 한다(빈 공간 어색함 제거).
    private var leadingReservation: CGFloat {
        (window?.styleMask.contains(.fullScreen) ?? false) ? 12 : 80
    }
    private let trailingReservation: CGFloat = 12
    private let tabSpacing: CGFloat = 2
    private let maxTabWidth: CGFloat = 200
    private let minTabWidth: CGFloat = 80
    private let tabHeight: CGFloat = 24

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // 투명 — 뒤의 NSVisualEffectView가 보이도록.
        layer?.backgroundColor = NSColor.clear.cgColor

        newTabButton.title = "+"
        newTabButton.bezelStyle = .inline
        newTabButton.isBordered = false
        newTabButton.font = NSFont.systemFont(ofSize: 16, weight: .light)
        newTabButton.contentTintColor = .secondaryLabelColor
        newTabButton.target = self
        newTabButton.action = #selector(newTabClicked)
        addSubview(newTabButton)

        // 우측 배지 — dev 빌드는 git hash(주황), 정식 빌드는 빌드 시각(은은한 색).
        if let badge = BuildInfo.badgeText {
            let l = NSTextField(labelWithString: badge)
            l.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            l.textColor = BuildInfo.isDevBuild ? .systemOrange : .tertiaryLabelColor
            l.alignment = .right
            addSubview(l)
            devLabel = l
        }
    }

    private var devLabel: NSTextField?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(titles: [String], selectedIndex: Int) {
        self.selectedIndex = selectedIndex
        // 기존 버튼 제거 후 재생성. 탭 수가 자주 변하지 않으므로 OK.
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()
        for (i, title) in titles.enumerated() {
            let btn = TabButton(title: title.isEmpty ? "Damson" : title,
                                isSelected: i == selectedIndex)
            btn.onClick = { [weak self] in self?.onTabSelected?(i) }
            btn.onClose = { [weak self] in self?.onTabClosed?(i) }
            btn.onRename = { [weak self] title in self?.onTabRenamed?(i, title) }
            btn.isReorderActive = { [weak self] in self?.reorderModeActive ?? false }
            btn.onDragBegan = { [weak self] in self?.beginDrag(i) }
            btn.onDragMoved = { [weak self] dx in self?.updateDrag(dx) }
            btn.onDragEnded = { [weak self] in self?.finishDrag() }
            if reorderModeActive { btn.setReorderMode(true) }
            addSubview(btn)
            tabButtons.append(btn)
        }
        needsLayout = true
    }

    // MARK: - Reorder mode (Cmd+Shift)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { installMonitor() } else { removeMonitor() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Restore the outgoing window's movability while we still hold its
        // reference; viewDidMoveToWindow runs after `window` is already nil.
        restoreWindowMovable()
    }

    deinit { removeMonitor() }

    /// Enter/leave reorder mode: pop the tabs out and pin window movability so
    /// the server doesn't eat the drag.
    private func setReorderMode(active: Bool) {
        guard active != reorderModeActive else { return }
        reorderModeActive = active
        tabButtons.forEach { $0.setReorderMode(active) }
        if active {
            if savedIsMovable == nil { savedIsMovable = window?.isMovable }
            window?.isMovable = false
        } else {
            if draggingIndex != nil { finishDrag() }
            restoreWindowMovable()
        }
    }

    private func restoreWindowMovable() {
        if let saved = savedIsMovable {
            window?.isMovable = saved
            savedIsMovable = nil
        }
    }

    private func installMonitor() {
        guard eventMonitor == nil else { return }
        // Only the Cmd+Shift chord is watched here. The drag runs through
        // TabButton's responder chain so AppKit's normal display cycle drives
        // the slide animations (no manual flush, no judder).
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged]
        ) { [weak self] event in
            self?.handleMonitorEvent(event) ?? event
        }
    }

    private func removeMonitor() {
        setReorderMode(active: false)
        restoreWindowMovable()
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }

    /// Toggle reorder mode on the Cmd+Shift chord. We never consume the event —
    /// the drag is handled by TabButton, and pinning `isMovable=false` (in
    /// setReorderMode) is what stops the window server from eating the drag.
    private func handleMonitorEvent(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, event.type == .flagsChanged else {
            return event
        }
        let active = event.modifierFlags.contains([.command, .shift])
        if active != reorderModeActive {
            setReorderMode(active: active)
        }
        return event
    }

    private func tabBaseX(_ i: Int) -> CGFloat {
        leadingReservation + CGFloat(i) * (perTab + tabSpacing)
    }

    /// Move a tab to a new x. View-backed layers have implicit animation
    /// disabled, so `animator().frame` is unreliable here; we set the model
    /// frame and add an explicit position animation from the current
    /// presentation point (smooth even if a prior slide was mid-flight).
    private func moveTab(_ view: NSView, toX x: CGFloat, animated: Bool) {
        let tabY = (bounds.height - tabHeight) / 2
        let newFrame = NSRect(x: x, y: tabY, width: perTab, height: tabHeight)
        guard animated, let layer = view.layer else {
            view.frame = newFrame
            return
        }
        let from = layer.presentation()?.position ?? layer.position
        view.frame = newFrame
        let anim = CABasicAnimation(keyPath: "position")
        anim.fromValue = NSValue(point: NSPoint(x: from.x, y: from.y))
        anim.toValue = NSValue(point: NSPoint(x: layer.position.x, y: layer.position.y))
        anim.duration = 0.16
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: "reorderSlide")
    }

    private func beginDrag(_ idx: Int) {
        guard idx < tabButtons.count else { return }
        draggingIndex = idx
        dragTargetIndex = idx
        lastGapTarget = idx
        let btn = tabButtons[idx]
        btn.layer?.zPosition = 10   // float above its neighbors
        btn.setGrabbed(true)
    }

    /// `dx` is the cursor offset from where this tab was grabbed, supplied by
    /// TabButton's responder-chain drag. The grabbed tab tracks the cursor; the
    /// neighbors glide to open a gap at the insertion slot.
    private func updateDrag(_ dx: CGFloat) {
        guard let idx = draggingIndex, idx < tabButtons.count else { return }
        let btn = tabButtons[idx]
        // The grabbed tab follows the cursor 1:1 (no animation on this one).
        btn.frame.origin.x = tabBaseX(idx) + dx
        // Insertion slot from displacement. Rounding gives a half-slot
        // hysteresis (no start jitter); the small same-direction bias commits
        // the swap a bit earlier (~⅓ slot) so wide tabs don't feel sluggish.
        let slotW = perTab + tabSpacing
        let step = (dx / slotW + CGFloat(copysign(0.15, Double(dx)))).rounded()
        let target = max(0, min(tabButtons.count - 1, idx + Int(step)))
        dragTargetIndex = target
        // Re-open the gap (animated) only when the insertion slot changes, so
        // neighbors glide once per crossing instead of restarting per pixel.
        guard target != lastGapTarget else { return }
        lastGapTarget = target
        var slot = 0
        for (i, other) in tabButtons.enumerated() where i != idx {
            if slot == target { slot += 1 }  // leave room for the dragged tab
            moveTab(other, toX: tabBaseX(slot), animated: true)
            slot += 1
        }
    }

    private func finishDrag() {
        guard let idx = draggingIndex else { return }
        draggingIndex = nil
        lastGapTarget = nil
        let target = dragTargetIndex ?? idx
        dragTargetIndex = nil
        guard idx < tabButtons.count else { return }
        let btn = tabButtons[idx]
        btn.setGrabbed(false)
        btn.layer?.zPosition = 0
        // Neighbors already sit in their final slots; glide the dropped tab into
        // its slot, then commit the model once the settle finishes so the
        // rebuild lands on positions that already match (no snap).
        guard target != idx else {
            moveTab(btn, toX: tabBaseX(idx), animated: true)   // snap back home
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.onTabReordered?(idx, target)
        }
        moveTab(btn, toX: tabBaseX(target), animated: true)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let btnSize: CGFloat = 24
        // dev 라벨 — 우측 끝. newTabButton은 그 왼쪽.
        var rightEdge = bounds.width - trailingReservation
        if let dev = devLabel {
            dev.sizeToFit()
            let w = dev.frame.width
            dev.frame = NSRect(x: rightEdge - w, y: (bounds.height - dev.frame.height) / 2,
                               width: w, height: dev.frame.height)
            rightEdge -= w + 8
        }
        newTabButton.frame = NSRect(
            x: max(leadingReservation, rightEdge - btnSize),
            y: (bounds.height - btnSize) / 2,
            width: btnSize, height: btnSize
        )

        guard !tabButtons.isEmpty else { return }
        let count = CGFloat(tabButtons.count)
        let available = bounds.width - leadingReservation - trailingReservation - btnSize - 4
            - tabSpacing * (count - 1)
        perTab = max(minTabWidth, min(maxTabWidth, available / count))
        let tabY = (bounds.height - tabHeight) / 2

        for (i, btn) in tabButtons.enumerated() {
            btn.frame = NSRect(
                x: leadingReservation + CGFloat(i) * (perTab + tabSpacing),
                y: tabY,
                width: perTab,
                height: tabHeight
            )
        }
        // new tab 버튼은 마지막 탭 오른쪽에 붙여둠.
        if let last = tabButtons.last {
            let nx = last.frame.maxX + 6
            if nx + btnSize + trailingReservation <= bounds.width {
                newTabButton.frame.origin.x = nx
            }
        }
    }

    @objc private func newTabClicked() {
        onNewTab?()
    }
}

/// One tab: title + trailing close X. Click selects, the X closes. In reorder
/// mode (Cmd+Shift) a horizontal drag is reported to the bar; the window is
/// pinned immovable then, so these drag events actually reach us.
private final class TabButton: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    /// Committed inline rename (Return or focus loss). "" reverts to the auto title.
    var onRename: ((String) -> Void)?
    /// Returns whether the bar is in Cmd+Shift reorder mode right now.
    var isReorderActive: (() -> Bool)?
    /// Drag-to-reorder callbacks. `dx` is the cursor's horizontal offset from
    /// the grab point, in window coordinates.
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    private var dragStartX: CGFloat?
    private var didDrag = false

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var isSelected: Bool

    init(title: String, isSelected: Bool) {
        self.isSelected = isSelected
        super.init(frame: .zero)
        wantsLayer = true
        updateBackground()

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 11)
        titleLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        closeButton.title = "✕"
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: 9)
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),
        ])

        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self, userInfo: nil
        )
        addTrackingArea(tracking)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Route all events to self except the close button, otherwise the title
    // label (an NSTextField) swallows mouseDown and clicks miss the tab.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !closeButton.isHidden, closeButton.frame.contains(local) {
            return closeButton
        }
        return bounds.contains(local) ? self : nil
    }

    private func updateBackground() {
        layer?.cornerRadius = 5
        layer?.backgroundColor = isSelected
            ? NSColor.white.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
    }

    /// Pop-out styling while Cmd+Shift reorder mode is active: accent border +
    /// a subtle lift so it reads as a draggable chip.
    func setReorderMode(_ on: Bool) {
        if on {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = NSColor.white
                .withAlphaComponent(isSelected ? 0.18 : 0.10).cgColor
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.25
            layer?.shadowRadius = 3
            layer?.shadowOffset = CGSize(width: 0, height: -1)
        } else {
            layer?.borderWidth = 0
            layer?.shadowOpacity = 0
            updateBackground()
        }
    }

    /// Stronger "lifted" styling while this tab is being dragged: deeper shadow
    /// and a brighter fill so it clearly reads as picked up. Releasing returns
    /// to the (still active) reorder-mode look.
    func setGrabbed(_ on: Bool) {
        if on {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.24).cgColor
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.5
            layer?.shadowRadius = 7
            layer?.shadowOffset = CGSize(width: 0, height: -2)
        } else {
            setReorderMode(true)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Claim the sequence; the click is acted on in mouseUp, a drag (in
        // reorder mode) in mouseDragged.
        dragStartX = event.locationInWindow.x
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startX = dragStartX, isReorderActive?() == true else { return }
        let dx = event.locationInWindow.x - startX
        if !didDrag, abs(dx) > 4 {
            didDrag = true
            onDragBegan?()
        }
        if didDrag { onDragMoved?(dx) }
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            onDragEnded?()
        } else if event.clickCount >= 2, isReorderActive?() != true {
            // 더블클릭 → 인라인 제목 편집. (단일 클릭은 selection.)
            beginEditing()
        } else {
            onClick?()
        }
        dragStartX = nil
        didDrag = false
    }

    @objc private func closeClicked() {
        onClose?()
    }

    // MARK: - Inline rename

    private var editField: NSTextField?

    private func beginEditing() {
        guard editField == nil else { return }
        let f = NSTextField(string: titleLabel.stringValue)
        f.font = titleLabel.font
        f.isBezeled = false
        f.drawsBackground = true
        f.backgroundColor = .textBackgroundColor
        f.textColor = .labelColor
        f.focusRingType = .none
        f.usesSingleLineMode = true
        f.lineBreakMode = .byTruncatingTail
        f.delegate = self
        f.translatesAutoresizingMaskIntoConstraints = false
        addSubview(f)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            f.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            f.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        editField = f
        titleLabel.isHidden = true
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }

    /// 편집 종료 — 필드 제거 + label 복원. editField를 먼저 nil로 해 재진입(controlTextDidEndEditing)을 막는다.
    private func endEditing() -> String? {
        guard let f = editField else { return nil }
        editField = nil
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        f.removeFromSuperview()
        titleLabel.isHidden = false
        return text
    }
}

extension TabButton: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            if let text = endEditing() { onRename?(text) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            _ = endEditing()   // Esc — 변경 취소
            return true
        default:
            return false
        }
    }

    // 포커스 상실(다른 곳 클릭)로 끝나면 현재 값으로 커밋.
    func controlTextDidEndEditing(_ obj: Notification) {
        if let text = endEditing() { onRename?(text) }
    }
}
