import AppKit
import Foundation
import DamsonControl
#if canImport(Darwin)
import Darwin
#endif

/// damson-cli ↔ damson 통신용 Unix domain socket 서버.
///
/// 라이프사이클:
///   1. `start(handler:)` — runtime dir 생성(0o700), stale socket sweep,
///      자기 PID 파일 unlink, bind, chmod 0o600, accept thread spawn.
///   2. accept thread는 한 connection = 한 command 패턴으로 동작.
///      JSON 한 줄 read → handler → 응답 한 줄 write → close.
///   3. handler는 worker thread에서 호출되므로 main actor 작업은 직접
///      DispatchQueue.main으로 hop 시키는 책임이 handler에 있음. 여기서는
///      thread 안전성 책임 안 짐.
final class ControlSocketServer {
    private var listenFd: Int32 = -1
    private var socketPath: String = ""
    private var thread: Thread?
    private var stopped = false

    /// handler: command → response. worker thread에서 호출됨.
    typealias Handler = (ControlCommand) -> ControlResponse

    /// 실패 시 throw. socketPath는 `damsonRuntimeDir()/{pid}.sock` 형태.
    @discardableResult
    func start(handler: @escaping Handler) throws -> String {
        let dir = damsonRuntimeDir()
        try createRuntimeDir(at: dir)
        sweepStaleSockets(in: dir)

        let pid = ProcessInfo.processInfo.processIdentifier
        let path = (dir as NSString).appendingPathComponent("\(pid).sock")
        // 자기 PID와 같은 파일이 남아있으면 (이전 SIGKILL 후 pid 재사용) 미리 제거.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ControlSocketError(
                "socket() failed: errno=\(errno)"
            )
        }
        if let err = bindOrConnectUnix(fd: fd, path: path, listen: true) {
            close(fd)
            throw ControlSocketError(err)
        }
        // 다른 사용자 접근 차단.
        chmod(path, 0o600)

        self.listenFd = fd
        self.socketPath = path

        let t = Thread { [weak self] in
            self?.acceptLoop(handler: handler)
        }
        t.name = "damson.control.accept"
        t.start()
        self.thread = t

        return path
    }

    func stop() {
        stopped = true
        if listenFd >= 0 {
            // shutdown으로 accept를 깨움.
            shutdown(listenFd, SHUT_RDWR)
            close(listenFd)
            listenFd = -1
        }
        if !socketPath.isEmpty {
            unlink(socketPath)
        }
    }

    deinit { stop() }

    private func createRuntimeDir(at dir: String) throws {
        let fm = FileManager.default
        try? fm.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        // 기존 디렉토리가 있어도 권한 조이기.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw ControlSocketError("runtime dir not a directory: \(dir)")
        }
    }

    private func sweepStaleSockets(in dir: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for name in names where name.hasSuffix(".sock") {
            let p = (dir as NSString).appendingPathComponent(name)
            if !isSocketLive(path: p) {
                unlink(p)
            }
        }
    }

    private func acceptLoop(handler: @escaping Handler) {
        while !stopped {
            var addr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let conn: Int32 = withUnsafeMutablePointer(to: &addr) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(listenFd, sa, &len)
                }
            }
            if conn < 0 {
                if stopped { return }
                if errno == EINTR { continue }
                if errno == EBADF || errno == EINVAL { return }
                // 일시적 에러 — 잠시 쉬고 재시도.
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            handleConnection(fd: conn, handler: handler)
        }
    }

    private func handleConnection(fd: Int32, handler: @escaping Handler) {
        defer { close(fd) }

        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
                   socklen_t(MemoryLayout.size(ofValue: tv)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv,
                   socklen_t(MemoryLayout.size(ofValue: tv)))

        var buf = [UInt8](repeating: 0, count: 65_536)
        var got = 0
        while got < buf.count {
            let n = buf.withUnsafeMutableBufferPointer { p -> Int in
                read(fd, p.baseAddress!.advanced(by: got), p.count - got)
            }
            if n <= 0 { break }
            got += n
            if buf[..<got].contains(0x0A) { break }
        }
        let nlIdx = buf[..<got].firstIndex(of: 0x0A) ?? got
        let payload = Data(buf[..<nlIdx])
        guard !payload.isEmpty else { return }

        let resp: ControlResponse
        do {
            let cmd = try JSONDecoder().decode(ControlCommand.self, from: payload)
            resp = handler(cmd)
        } catch {
            resp = .err("parse error: \(error)")
        }

        var out: Data
        do {
            out = try JSONEncoder().encode(resp)
        } catch {
            return
        }
        out.append(0x0A)
        var sent = 0
        out.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.baseAddress!
            while sent < out.count {
                let n = write(fd, p.advanced(by: sent), out.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}

struct ControlSocketError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { self.message = m }
    var description: String { message }
}
