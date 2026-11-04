import Foundation

/// 协议层占位，下一步写入 Noise IK 与 Control/Relay 传输。
public enum DSHBridgeProtocol {
    public static let protocolVersion = 1
    public static let defaultServer = "https://dsh.r2049.cn"
    public static let defaultRelay = "wss://gz-turn.r2049.cn/ws"
}
