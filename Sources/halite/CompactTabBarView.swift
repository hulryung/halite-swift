import AppKit

/// Compact 모드 전용 커스텀 탭 바. NSWindow 네이티브 탭을 끄고
/// (tabbingMode = .disallowed) 이걸 contentView 최상단에 배치 → 신호등과
/// 같은 row에 탭이 보임.
///
/// 구조:
///   [80pt 비워둠 (신호등 영역)][탭 1][탭 2]...[탭 N][+ 새 탭][여백]
final class CompactTabBarView: NSView {
    var onTabSelected: ((Int) -> Void)?
    var onTabClosed: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    /// Reorder result after a drag: move the tab from `from` to `to`.
    var onTabReordered: ((Int, Int) -> Void)?

    private var tabButtons: [TabButton] = []
    private let newTabButton = NSButton()
    private var selectedIndex: Int = 0

    // Drag-reorder state.
    private var perTab: CGFloat = 100   // current per-tab width (updated in layout)
    private var dragTargetIndex: Int?

    private let leadingReservation: CGFloat = 80   // 신호등 자리
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

        // dev 빌드면 우측에 git hash 표시 (정식과 구분).
        if BuildInfo.isDevBuild {
            devLabel = NSTextField(labelWithString: "dev \(BuildInfo.gitHash ?? "")")
            devLabel?.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            devLabel?.textColor = NSColor.systemOrange
            devLabel?.alignment = .right
            if let l = devLabel { addSubview(l) }
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
            let btn = TabButton(title: title.isEmpty ? "halite" : title,
                                isSelected: i == selectedIndex)
            btn.index = i
            btn.onClick = { [weak self] in self?.onTabSelected?(i) }
            btn.onClose = { [weak self] in self?.onTabClosed?(i) }
            btn.onDragBegan = { [weak self] idx in self?.dragBegan(idx) }
            btn.onDragMoved = { [weak self] idx, dx in self?.dragMoved(idx, dx) }
            btn.onDragEnded = { [weak self] idx in self?.dragEnded(idx) }
            addSubview(btn)
            tabButtons.append(btn)
        }
        needsLayout = true
    }

    // MARK: - Drag to reorder

    private func tabBaseX(_ i: Int) -> CGFloat {
        leadingReservation + CGFloat(i) * (perTab + tabSpacing)
    }

    private func dragBegan(_ idx: Int) {
        guard idx < tabButtons.count else { return }
        tabButtons[idx].layer?.zPosition = 10
        dragTargetIndex = idx
    }

    private func dragMoved(_ idx: Int, _ dx: CGFloat) {
        guard idx < tabButtons.count else { return }
        let btn = tabButtons[idx]
        // Follow the cursor horizontally from the tab's home slot.
        btn.frame.origin.x = tabBaseX(idx) + dx
        // Which slot does the dragged tab's center fall into?
        let center = btn.frame.midX
        var target = 0
        for i in 0..<tabButtons.count {
            let slotCenter = tabBaseX(i) + perTab / 2
            if center >= slotCenter { target = i }
        }
        dragTargetIndex = target
        // Shift the other tabs to open a gap at `target`.
        let tabY = (bounds.height - tabHeight) / 2
        var slot = 0
        for (i, other) in tabButtons.enumerated() where i != idx {
            if slot == target { slot += 1 }  // leave room for the dragged tab
            other.frame = NSRect(x: tabBaseX(slot), y: tabY, width: perTab, height: tabHeight)
            slot += 1
        }
    }

    private func dragEnded(_ idx: Int) {
        guard idx < tabButtons.count else { return }
        tabButtons[idx].layer?.zPosition = 0
        let target = dragTargetIndex ?? idx
        dragTargetIndex = nil
        if target != idx {
            onTabReordered?(idx, target)
        } else {
            needsLayout = true  // snap back
        }
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

/// One tab: title + trailing close X. Supports click, close, and drag-to-reorder.
private final class TabButton: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    /// Drag-to-reorder callbacks. dx is the cumulative horizontal offset from
    /// the drag start (in this view's window coordinates).
    var onDragBegan: ((Int) -> Void)?
    var onDragMoved: ((Int, CGFloat) -> Void)?
    var onDragEnded: ((Int) -> Void)?
    /// This tab's index in the bar; set by CompactTabBarView on layout.
    var index: Int = 0

    private var dragStart: NSPoint?
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

    private func updateBackground() {
        layer?.cornerRadius = 5
        layer?.backgroundColor = isSelected
            ? NSColor.white.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        // Clicks on the close button are handled there; this only fires elsewhere.
        dragStart = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let dx = event.locationInWindow.x - start.x
        if !didDrag && abs(dx) > 4 {
            didDrag = true
            onDragBegan?(index)
        }
        if didDrag {
            onDragMoved?(index, dx)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            onDragEnded?(index)
        } else {
            onClick?()
        }
        dragStart = nil
        didDrag = false
    }

    @objc private func closeClicked() {
        onClose?()
    }
}
