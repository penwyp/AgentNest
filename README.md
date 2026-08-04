# AgentNest

AgentNest 是一个面向 macOS 的原生 Agent 环境管理器。本仓库当前包含：

- Swift 6 / SwiftUI 客户端与可复用领域层；
- 声明式 Agent Definition、深度扫描、物理空间账本；
- Skill 虚拟索引、安全创建/补齐执行器与统一清理策略；
- 基础活动采样、默认关闭的 SQLite 历史和 CSV 导出；
- Go 设备试用/License 服务、Ed25519 Receipt、支付 webhook；
- 使用真实客户端和服务端产物的本地 E2E。

完整范围、进度和外部依赖见 [TASKLIST.md](TASKLIST.md)。`prd.md` 是产品真源。

## 构建与测试

```bash
make build
make test
make e2e
make check
```

本机只有 Command Line Tools、没有完整 Xcode 的 XCTest 运行时，因此 Swift 核心测试使用零依赖的编译型 `agentnest-core-tests` runner；测试失败仍以非零状态退出。安装完整 Xcode 后，发布阶段还需执行 universal2、签名、公证、staple 和 UI/accessibility 测试。

## 本地授权服务

```bash
AGENTNEST_DEVELOPMENT_LICENSE_KEY=LOCAL-TEST-KEY \
  .artifacts/bin/agentnest-license-server \
  --listen 127.0.0.1:8080 \
  --data .local/license
```

服务首次启动生成并以 `0600` 保存本地 Ed25519 私钥。客户端只接收固定公钥；开发调试构建运行 GUI 时可注入：

```bash
AGENTNEST_LICENSE_SERVER_URL=http://127.0.0.1:8080 \
AGENTNEST_LICENSE_PUBLIC_KEY='<base64url public key>' \
  .build/debug/AgentNestApp
```

release 构建不会读取环境变量中的公钥。生产打包必须在签名前固定服务地址和验签公钥，例如：

```bash
make build LICENSE_SERVER_URL='https://license.example.com' LICENSE_PUBLIC_KEY='<base64url public key>'
```

支付 webhook 另需设置 `AGENTNEST_PAYMENT_WEBHOOK_SECRET`。
