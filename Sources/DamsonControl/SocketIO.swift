import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 클라이언트가 한 명령을 보내고 한 응답을 읽는 단일 라운드트립.
/// timeout은 connect / read / write 각각에 적용.
/// `socketPath`에 connect → JSON line write → 한 줄 read → 파싱.
public enum SocketIOError: Error, CustomStringConvertible {
    case connect(String)
    case write(String)
    case read(String)
    case decode(String)
    case timeout

    public var description: String {
        switch self {
        case .connect(let m): return "connect: \(m)"
        case .write(let m): return "write: \(m)"
        case .read(let m): return "read: \(m)"
        case .decode(let m): return "decode: \(m)"
        case .timeout: return "timeout"
        }
    }
}

public func sendCommand(
    socketPath: String,
    commandJSON: String,
    timeout: TimeInterval = 5.0
) -> Result<ControlResponse, SocketIOError> {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        return .failure(.connect("socket() failed: errno=\(errno)"))
    }
    defer { close(fd) }

    if let err = bindOrConnectUnix(fd: fd, path: socketPath, listen: false) {
        return .failure(.connect(err))
    }

    let sec = Int(timeout)
    let usec = Int32((timeout - Double(sec)) * 1_000_000)
    var tv = timeval(tv_sec: sec, tv_usec: suseconds_t(usec))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))

    // Request: JSON + \n
    var req = Array(commandJSON.utf8)
    req.append(0x0A)
    var sent = 0
    while sent < req.count {
        let n = req.withUnsafeBufferPointer { buf -> Int in
            write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
        }
        if n <= 0 {
            return .failure(.write("write() returned \(n), errno=\(errno)"))
        }
        sent += n
    }

    // Read until \n (or EOF). 응답 한 개만이므로 64KB 충분.
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
    let endIdx = buf[..<got].firstIndex(of: 0x0A) ?? got
    let data = Data(buf[..<endIdx])
    guard !data.isEmpty else {
        return .failure(.read("server closed without response"))
    }
    do {
        let resp = try JSONDecoder().decode(ControlResponse.self, from: data)
        return .success(resp)
    } catch {
        return .failure(.decode("\(error)"))
    }
}

/// `sockaddr_un` 채우기. listen=false면 connect, true면 bind+listen.
/// 성공 시 nil, 실패 시 에러 메시지.
public func bindOrConnectUnix(fd: Int32, path: String, listen doListen: Bool) -> String? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < cap else {
        return "path too long (\(bytes.count) >= \(cap) bytes)"
    }
    // 1단계: addr.sun_path 채움 (& 단독 접근).
    withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
        let dst = UnsafeMutableRawPointer(tuplePtr).assumingMemoryBound(to: CChar.self)
        for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
        dst[bytes.count] = 0
    }
    // 2단계: addr 전체 포인터를 sockaddr로 reinterpret해서 syscall (별도 접근).
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result: Int32 = withUnsafePointer(to: &addr) { ap -> Int32 in
        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa -> Int32 in
            doListen ? bind(fd, sa, len) : connect(fd, sa, len)
        }
    }
    if result != 0 {
        return "\(doListen ? "bind" : "connect")() failed: errno=\(errno) (\(String(cString: strerror(errno))))"
    }
    if doListen {
        if Darwin.listen(fd, 16) != 0 {
            return "listen() failed: errno=\(errno)"
        }
    }
    return nil
}
