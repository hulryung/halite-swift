import Foundation

/// Pure, view-independent helpers behind mouse text selection. Kept free of
/// AppKit / Grid so the tricky parts (soft-wrap copy joining, block column math,
/// separator-aware word bounds, smart-selection rules, semantic ranges from
/// prompt marks) are unit-testable in isolation. `DamsonSurfaceView` adapts its
/// live grid into these primitives.
public enum SelectionLogic {

    // MARK: - Word separators

    /// A character is a word break if it appears in `separators`. The default set
    /// is whitespace/tab only; callers may pass a richer set so identifiers and
    /// paths (which keep `-_/.` as word chars) select cleanly.
    public static func isWordBreak(_ c: Character, separators: String) -> Bool {
        if c == " " || c == "\t" { return true }
        return separators.contains(c)
    }

    /// The half-open column span [start, end) of the word containing `col` in
    /// `chars`, using `separators`. Returns nil when `col` is out of range or on
    /// a separator (i.e. not part of a word).
    public static func wordSpan(
        in chars: [Character], col: Int, separators: String
    ) -> Range<Int>? {
        guard col >= 0, col < chars.count else { return nil }
        if isWordBreak(chars[col], separators: separators) { return nil }
        var start = col
        while start > 0 && !isWordBreak(chars[start - 1], separators: separators) {
            start -= 1
        }
        var end = col + 1
        while end < chars.count && !isWordBreak(chars[end], separators: separators) {
            end += 1
        }
        return start..<end
    }

    // MARK: - Soft-wrap-aware copy

    /// One selected row's contribution to a copy: its visible characters (wide-char
    /// continuation cells already dropped by the caller) plus whether the row is
    /// soft-wrapped into the next row (so no hard newline should follow it).
    public struct CopyRow {
        public var text: String
        /// True if this row soft-wraps into the following selected row.
        public var wrappedToNext: Bool
        public init(text: String, wrappedToNext: Bool) {
            self.text = text
            self.wrappedToNext = wrappedToNext
        }
    }

    /// Join selected rows into copy text. Consecutive rows belonging to one
    /// soft-wrapped logical line are concatenated WITHOUT a newline; a real hard
    /// line break emits "\n". Trailing spaces are trimmed per row EXCEPT at a
    /// soft-wrap join point, where the spaces are part of the logical line.
    public static func joinForCopy(_ rows: [CopyRow]) -> String {
        var out = ""
        for (i, row) in rows.enumerated() {
            let isLast = (i == rows.count - 1)
            // Trim trailing spaces only when this row ends a logical line (hard
            // break or end of selection). At a soft-wrap join the spaces belong
            // to the wrapped line and must be preserved.
            var text = row.text
            if !row.wrappedToNext || isLast {
                while text.last == " " { text.removeLast() }
            }
            out += text
            if !isLast && !row.wrappedToNext {
                out += "\n"
            }
        }
        return out
    }

    // MARK: - Block (rectangular) selection column math

    /// The shared column slice [lo, hi) applied to every row of a block selection,
    /// clamped to `cols`. Returns nil when the slice is empty.
    public static func blockColumns(
        anchorCol: Int, headCol: Int, cols: Int
    ) -> Range<Int>? {
        let lo = max(0, min(anchorCol, headCol))
        let hi = min(cols, max(anchorCol, headCol))
        return lo < hi ? lo..<hi : nil
    }

    // MARK: - Smart selection rules

    /// An ordered set of recognizers tried at double-click before falling back to
    /// plain (separator-aware) word selection. Each returns the half-open char
    /// range of the matched token covering `index`, or nil.
    ///
    /// Note: there is intentionally no generic "identifier" rule here — plain
    /// words are left to the caller's `wordSpan` so the user's configurable word
    /// separators stay authoritative. Smart rules only fire for the structured
    /// tokens (URL / email / path) that benefit from dedicated recognition.
    public enum SmartRule: CaseIterable {
        case url, email, path
    }

    /// Try each smart rule in order against `text`, returning the first token
    /// range that contains the character `index`. nil means no rule matched.
    public static func smartTokenRange(
        in text: String, at index: Int
    ) -> Range<Int>? {
        let chars = Array(text)
        guard index >= 0, index < chars.count else { return nil }
        for rule in SmartRule.allCases {
            if let r = match(rule: rule, chars: chars, index: index) { return r }
        }
        return nil
    }

    private static func match(rule: SmartRule, chars: [Character], index: Int) -> Range<Int>? {
        switch rule {
        case .url:
            return regexTokenRange(
                chars, index,
                pattern: #"(https?|file)://[^\s'"()<>\[\]{}]+"#)
        case .email:
            return regexTokenRange(
                chars, index,
                pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)
        case .path:
            // ~-, /-, ./- prefixed, or any run containing a slash. Stops at
            // whitespace and shell-unfriendly delimiters.
            if let r = contiguousTokenRange(
                chars, index,
                allowed: { !" \t\"'()<>".contains($0) }
            ), tokenIsPath(chars, r) {
                return r
            }
            return nil
        }
    }

    private static func tokenIsPath(_ chars: [Character], _ r: Range<Int>) -> Bool {
        let slice = chars[r]
        if slice.first == "~" || slice.first == "/" { return true }
        if slice.count >= 2 && slice.first == "." && chars[r.lowerBound + 1] == "/" { return true }
        return slice.contains("/")
    }

    /// Expand left/right from `index` while `allowed` holds. Returns nil if the
    /// char at `index` itself isn't allowed.
    private static func contiguousTokenRange(
        _ chars: [Character], _ index: Int, allowed: (Character) -> Bool
    ) -> Range<Int>? {
        guard allowed(chars[index]) else { return nil }
        var start = index
        while start > 0 && allowed(chars[start - 1]) { start -= 1 }
        var end = index + 1
        while end < chars.count && allowed(chars[end]) { end += 1 }
        return start..<end
    }

    /// Run `pattern` over the whole string and return the match range (in char
    /// offsets) that contains `index`, if any.
    private static func regexTokenRange(
        _ chars: [Character], _ index: Int, pattern: String
    ) -> Range<Int>? {
        let text = String(chars)
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        for m in re.matches(in: text, range: full) {
            // Convert the UTF-16 match range to Character offsets.
            guard let swiftRange = Range(m.range, in: text) else { continue }
            let lower = text.distance(from: text.startIndex, to: swiftRange.lowerBound)
            let upper = text.distance(from: text.startIndex, to: swiftRange.upperBound)
            if index >= lower && index < upper { return lower..<upper }
        }
        return nil
    }

    // MARK: - Semantic (command) selection from prompt marks

    /// Given the unified-row indices of prompt-start marks (OSC 133;A) and the
    /// current cursor row, return the inclusive [startRow, endRow] of the most
    /// recent command's output. The most recent prompt sits at the last mark; the
    /// command echo + its output run from the row below that prompt down to the
    /// cursor. Returns nil when there are no usable marks. The start is clamped to
    /// the cursor so an empty (cursor-on-prompt) region still yields a valid range.
    public static func lastCommandOutputRows(
        promptRows: [Int], cursorRow: Int
    ) -> ClosedRange<Int>? {
        guard let last = promptRows.max() else { return nil }
        let start = last + 1
        let end = max(start, cursorRow)
        return start...end
    }
}
