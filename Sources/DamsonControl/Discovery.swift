import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `damsonRuntimeDir()` — damson control socket이 사는 디렉토리.
/// 우선순위:
///   1. `$XDG_RUNTIME_DIR/damson`
///   2. `$TMPDIR/damson-{uid}` (macOS 기본 — TMPDIR이 항상 set)
///   3. `/tmp/damson-{uid}` (최후 fallback)
/// (디렉토리 규칙은 Rust halite의 `runtime_dir`에서 유래.)
public func damsonRuntimeDir() -> String {
    let env = ProcessInfo.processInfo.environment
    if let xdg = env["XDG_RUNTIME_DIR"], !xdg.isEmpty {
        return (xdg as NSString).appendingPathComponent("damson")
    }
    let uid = getuid()
    if let tmp = env["TMPDIR"], !tmp.isEmpty {
        // TMPDIR은 보통 trailing slash 있음 — NSString이 정리.
        return (tmp as NSString).appendingPathComponent("damson-\(uid)")
    }
    return "/tmp/damson-\(uid)"
}

/// 디스크에서 발견된 한 damson 인스턴스.
public struct DamsonInstance: Sendable {
    public let pid: Int
    public let socketPath: String
    public let mtime: Date?
}

/// 실행 중인 damson 인스턴스 목록 (newest first).
/// "실행 중" = socket file 존재 + connect 시 즉시 `ECONNREFUSED`가 아님.
public func listDamsonInstances() -> [DamsonInstance] {
    let dir = damsonRuntimeDir()
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: dir) else {
        return []
    }
    var found: [DamsonInstance] = []
    for name in names {
        guard name.hasSuffix(".sock") else { continue }
        let stem = String(name.dropLast(5))
        guard let pid = Int(stem), pid > 0 else { continue }
        let path = (dir as NSString).appendingPathComponent(name)
        guard isSocketLive(path: path) else { continue }
        let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        found.append(DamsonInstance(pid: pid, socketPath: path, mtime: mtime))
    }
    found.sort { (a, b) in
        let am = a.mtime ?? .distantPast
        let bm = b.mtime ?? .distantPast
        return am > bm
    }
    return found
}

public struct PickSocketError: Error, CustomStringConvertible, Equatable, Sendable {
    public let message: String
    public init(_ m: String) { self.message = m }
    public var description: String { message }
}

/// `--pid`가 주어지면 해당 인스턴스, 없으면 가장 최근 mtime의 인스턴스.
public func pickDamsonSocket(pid: Int?) -> Result<String, PickSocketError> {
    let instances = listDamsonInstances()
    if let want = pid {
        if let m = instances.first(where: { $0.pid == want }) {
            return .success(m.socketPath)
        }
        return .failure(PickSocketError("no damson instance with pid \(want)"))
    }
    if let first = instances.first {
        return .success(first.socketPath)
    }
    return .failure(PickSocketError(
        "no running damson instance found (try `damson-cli --list-instances`)"
    ))
}

/// connect를 시도해 본 후 즉시 끊는다. 살아있으면 true.
public func isSocketLive(path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    return bindOrConnectUnix(fd: fd, path: path, listen: false) == nil
}
