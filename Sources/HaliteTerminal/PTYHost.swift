import Darwin
import Foundation

/// 자식 셸을 PTY 위에서 띄우고 read/write/resize/wait를 관리.
/// 읽기는 dedicated thread, 콜백은 main queue로 호핑됨.
public final class PTYHost {
    public enum SpawnError: Error {
        case forkptyFailed(errno: Int32)
    }

    public var onData: ((Data) -> Void)?
    public var onExit: ((Int32) -> Void)?

    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var isReading = false

    private let readQueue = DispatchQueue(label: "halite.pty.read", qos: .userInteractive)
    private let waitQueue = DispatchQueue(label: "halite.pty.wait", qos: .utility)

    public init() {}

    /// 자식 셸 프로세스의 현재 작업 디렉토리. proc_pidinfo로 OS에서 직접 조회하므로
    /// 셸 설정(OSC 7 emit 여부 등)과 무관. 세션 상태 복원 시 사용. 자식이 없거나
    /// 조회 실패면 nil.
    public var childWorkingDirectory: String? {
        guard childPID > 0 else { return nil }
        var vpi = proc_vnodepathinfo()
        let sz = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let r = proc_pidinfo(childPID, PROC_PIDVNODEPATHINFO, 0, &vpi, sz)
        guard r == sz else { return nil }
        return withUnsafePointer(to: &vpi.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    /// PTY의 foreground process group이 셸 자신(childPID, = 셸의 pgid)과 다르면 true —
    /// 즉 셸이 프롬프트에서 대기 중이 아니라 어떤 명령을 foreground로 실행 중일 때.
    /// 종료 확인 다이얼로그가 "셸만 떠 있는 경우"는 묻지 않도록 판정에 사용.
    public var isRunningForegroundJob: Bool {
        guard childPID > 0, masterFD >= 0 else { return false }
        let fg = tcgetpgrp(masterFD)
        return fg > 0 && fg != childPID
    }

    deinit {
        terminate()
    }

    public func spawn(
        argv: [String],
        env: [String: String],
        cwd: String?,
        cols: Int = 80,
        rows: Int = 24
    ) throws {
        precondition(!argv.isEmpty, "argv must not be empty")

        var ws = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        var master: Int32 = 0
        let pid = forkpty(&master, nil, nil, &ws)

        if pid < 0 {
            throw SpawnError.forkptyFailed(errno: errno)
        }

        if pid == 0 {
            // === 자식 프로세스 ===
            if let cwd = cwd {
                _ = chdir(cwd)
            }

            // argv → C
            let argvCStrings: [UnsafeMutablePointer<CChar>?] =
                argv.map { strdup($0) } + [nil]

            // env → "KEY=VALUE" C 문자열 배열
            let envCStrings: [UnsafeMutablePointer<CChar>?] =
                env.map { strdup("\($0.key)=\($0.value)") } + [nil]

            argvCStrings.withUnsafeBufferPointer { argvBuf in
                envCStrings.withUnsafeBufferPointer { envBuf in
                    _ = execve(
                        argv[0],
                        UnsafeMutablePointer(mutating: argvBuf.baseAddress),
                        UnsafeMutablePointer(mutating: envBuf.baseAddress)
                    )
                }
            }

            // execve 실패 — 자식에서 즉시 종료
            _exit(127)
        }

        // === 부모 프로세스 ===
        masterFD = master
        childPID = pid

        startReading()
        startWaiting()
    }

    public func write(_ data: Data) {
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var remaining = buf.count
            var ptr = base
            while remaining > 0 {
                let n = Darwin.write(masterFD, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if n == 0 { return }
                remaining -= n
                ptr = ptr.advanced(by: n)
            }
        }
    }

    public func resize(cols: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        var ws = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
    }

    public func terminate() {
        // ⚠️ macOS PTY: read thread가 master fd에서 read() blocking 중일 때
        // 다른 스레드에서 close(fd)를 부르면 read가 종료될 때까지 close가
        // **blocking**된다. main thread에서 호출되는 windowWillClose 경로에서
        // 이 동작이 일어나면 UI 전체가 freeze (예: 사용자의 Cmd+W).
        // → kill + close를 background queue로 옮기고 main은 즉시 반환.
        let pidToKill = childPID
        let fdToClose = masterFD
        isReading = false
        childPID = -1
        masterFD = -1

        DispatchQueue.global(qos: .utility).async {
            if pidToKill > 0 {
                kill(pidToKill, SIGTERM)
                // shell이 SIGTERM 무시(vim 등 foreground app이 잡고 있는 경우)
                // 면 1초 grace 후 강제 종료. 데이터 보존보다 응답성 우선
                // (사용자가 명시적으로 닫기를 요청한 시점이므로).
                Thread.sleep(forTimeInterval: 1.0)
                kill(pidToKill, SIGKILL)
            }
            if fdToClose >= 0 {
                close(fdToClose)
            }
        }
    }

    // MARK: - Internals

    private func startReading() {
        isReading = true
        let fd = masterFD
        readQueue.async { [weak self] in
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while self?.isReading == true {
                let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                    read(fd, ptr.baseAddress, ptr.count)
                }
                if n > 0 {
                    let chunk = Data(buffer.prefix(n))
                    DispatchQueue.main.async {
                        self?.onData?(chunk)
                    }
                } else if n == 0 {
                    return // EOF
                } else {
                    if errno == EINTR { continue }
                    return
                }
            }
        }
    }

    private func startWaiting() {
        let pid = childPID
        waitQueue.async { [weak self] in
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)

            let code: Int32
            if (status & 0x7F) == 0 {
                code = (status >> 8) & 0xFF
            } else {
                code = -1
            }
            DispatchQueue.main.async {
                self?.onExit?(code)
            }
        }
    }
}
