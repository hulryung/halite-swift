import Foundation

/// `DamsonSession`이 파서를 통해 발행하는 의미적 출력 이벤트.
/// 호스트(뷰/렌더러)가 case에 따라 분기.
public enum DamsonOutputEvent {
    case text(String)
    case execute(UInt8)
    case csi(params: [Int], intermediates: [UInt8], finalByte: UInt8, privateMarker: UInt8?)
    case osc([String])
}
