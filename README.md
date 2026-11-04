# DSH Bridge

iOS 26+ 原生客户端，用于远程连接自己的 DSH desktop。

- 最低系统：iOS 26，SwiftUI + Liquid Glass，无 availability 分支
- 传输：WSS Relay（v1 不做 WebRTC/P2P）
- 加密：Noise_IK_25519_ChaChaPoly_SHA256
- 协议：DSH Remote Protocol v1（见 Fixtures/protocol-v1.md）
- 一致性基线：Fixtures/noise-ik.json

## 目录

- `Sources/DSHBridgeProtocol/Crypto` — Noise IK、X25519、ChaChaPoly、SecureMessageCodec
- `Sources/DSHBridgeProtocol/Transport` — REST、Control WebSocket、Relay 数据面
- `Sources/DSHBridgeApp` — SwiftUI 界面
- `Tests/DSHBridgeProtocolTests` — 对官方向量的字节级验证

## 服务器

默认 `https://dsh.r2049.cn`，中继节点在 `wss://gz-turn.r2049.cn/ws`。
