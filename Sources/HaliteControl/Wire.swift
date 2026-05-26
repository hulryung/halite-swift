import Foundation

/// halite-cli ↔ halite 서버 간의 NDJSON wire-format 타입.
/// Rust halite의 `docs/CLI.md` 명세와 동일하게 직렬화되도록 인코딩/디코딩을
/// 수동 구현. 그래서 같은 `halite-cli`(Rust)도 우리 halite-swift 서버와 통신
/// 가능하고, 우리 `halite-cli`(Swift)도 Rust halite 서버에 붙음.

public enum SplitDir: String, Codable, Sendable {
    case horizontal
    case vertical
}

public enum ControlCommandKind: Equatable, Sendable {
    case newTab
    case split(SplitDir)
    case switchTab(index: Int)
    case closeTab
    case listTabs
}

/// 들어오는 명령. JSON: `{"cmd":"new-tab"}`, `{"cmd":"split","args":{"dir":"horizontal"}}` 등.
public struct ControlCommand: Decodable, Equatable, Sendable {
    public let kind: ControlCommandKind

    public init(kind: ControlCommandKind) { self.kind = kind }

    enum CodingKeys: String, CodingKey { case cmd, args }
    private struct SplitArgs: Decodable { let dir: SplitDir }
    private struct SwitchArgs: Decodable { let index: Int }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .cmd)
        switch name {
        case "new-tab":
            self.kind = .newTab
        case "close-tab":
            self.kind = .closeTab
        case "list-tabs":
            self.kind = .listTabs
        case "split":
            let a = try c.decode(SplitArgs.self, forKey: .args)
            self.kind = .split(a.dir)
        case "switch-tab":
            let a = try c.decode(SwitchArgs.self, forKey: .args)
            self.kind = .switchTab(index: a.index)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .cmd, in: c,
                debugDescription: "unknown command: \(name)"
            )
        }
    }
}

/// CLI에서 명령 → JSON 직렬화. Rust 측의 `cmd_to_json`과 동일한 출력 (키 순서까지).
public func encodeCommand(_ kind: ControlCommandKind) -> String {
    switch kind {
    case .newTab: return #"{"cmd":"new-tab"}"#
    case .closeTab: return #"{"cmd":"close-tab"}"#
    case .listTabs: return #"{"cmd":"list-tabs"}"#
    case .split(let d):
        return #"{"cmd":"split","args":{"dir":"\#(d.rawValue)"}}"#
    case .switchTab(let i):
        return #"{"cmd":"switch-tab","args":{"index":\#(i)}}"#
    }
}

/// 한 줄의 list-tabs 결과.
public struct TabInfo: Codable, Equatable, Sendable {
    public let index: Int
    public let pane_count: Int
    public init(index: Int, pane_count: Int) {
        self.index = index
        self.pane_count = pane_count
    }
}

/// 응답. 성공: `{"ok":true}` (+ optional tabs), 실패: `{"ok":false,"err":"..."}`.
public struct ControlResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let err: String?
    public let tabs: [TabInfo]?

    public init(ok: Bool, err: String? = nil, tabs: [TabInfo]? = nil) {
        self.ok = ok
        self.err = err
        self.tabs = tabs
    }

    public static func ok() -> Self { .init(ok: true) }
    public static func err(_ msg: String) -> Self { .init(ok: false, err: msg) }
    public static func tabs(_ list: [TabInfo]) -> Self {
        .init(ok: true, tabs: list)
    }

    enum CodingKeys: String, CodingKey { case ok, err, tabs }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ok, forKey: .ok)
        if let err = err { try c.encode(err, forKey: .err) }
        if let tabs = tabs { try c.encode(tabs, forKey: .tabs) }
    }
}
