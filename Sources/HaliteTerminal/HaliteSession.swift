import AppKit
import Combine
import Foundation

/// 터미널 인스턴스 1개. PTY + 파서 + Grid + 렌더 상태를 묶음.
/// 호스트(cmux / halite.app)가 생성·소유하고 `HaliteTerminalView`에 주입.
public final class HaliteSession: ObservableObject {
    public private(set) var config: HaliteConfig

    @Published public private(set) var title: String = ""
    @Published public private(set) var workingDirectory: String? = nil
    @Published public private(set) var processExited: Bool = false
    public private(set) var exitCode: Int32? = nil

    // 호스트가 구독하는 콜백. weak 캡처 권장.
    public var onTitleChanged: ((String) -> Void)?
    public var onBell: (() -> Void)?
    public var onExit: ((Int32) -> Void)?
    public var onURLClick: ((URL) -> Void)?
    public var onClipboardWrite: ((String) -> Void)?

    public init(config: HaliteConfig) {
        self.config = config
        // TODO(M1): PTYHost + VTParser + Grid 와이어업
    }

    /// 키 이벤트 외의 추가 입력 (예: 호스트가 합성한 텍스트).
    public func write(_ bytes: Data) {
        // TODO(M1): PTYHost.write 위임
    }

    public func resize(cols: Int, rows: Int) {
        // TODO(M1): PTY winsize + Grid resize
    }

    public func clearSelection() {
        // TODO(M8)
    }

    /// 폰트/색상/팔레트 변경 등 hot-reload 시 호출.
    public func updateConfig(_ config: HaliteConfig) {
        self.config = config
        // TODO: 렌더러/아틀라스/파서로 전파
    }
}
