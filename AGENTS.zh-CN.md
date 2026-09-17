[English](AGENTS.md) · **简体中文**

# SecretBox（代理工作约定）

AI 原生密码管理器，面向企业与个人——人与 AI agent 之间的密钥保险箱（明文绝不进入 agent 上下文）。内置运维模板（redis、s3、database、kafka、custom），同样覆盖日常账号。两个组件：

- `SecretBox/` — SwiftUI 应用（macOS 菜单栏 + 窗口 / iPhone），Xcode 工程位于 `SecretBox/SecretBox.xcodeproj`，源码在 `SecretBox/SecretBox/`，主题在 `SecretBox/SecretBox/Docs/AppTheme.swift`。
- `server/` — FastAPI + SQLAlchemy + SQLite 后端（`server/app/`），测试在 `server/tests/`。

## 测试 / 构建

- `./scripts/test.sh` — 全量：macOS 应用测试 + 服务器 pytest。
- `./scripts/test-macos.sh` — 应用回归套件（xcodebuild，scheme `SecretBox`，`platform=macOS`，derived data 在 `.derived/`）。
- `./scripts/test-sample-set-macos.sh` — 仅 50 样本分类器回归。
- `./scripts/test-ios.sh` — iOS 模拟器单元测试 + 50 样本回归（`platform=iOS Simulator,name=iPhone 17`，derived data 在 `.derived-ios/`）。
- 服务器测试：`cd server && python3 -m pytest tests`（依赖见 `server/requirements.txt`）。
- MCP 测试：`cd mcp-server && python3 -m pytest test_secretbox_mcp.py`。
- 本地跑服务器：`cd server && docker compose up --build`（FastAPI 在 127.0.0.1:8000）。
- 灌演示数据：`cd server && python3 scripts/seed_demo.py`。

详见 `TESTING.md`；注意 macOS UI 测试在非普通 Terminal/Xcode 环境下可能报 `Sandbox restriction` / `testmanagerd` 错误。

## 安全模型（改代码前必读）

改动 `server/app/security.py`、`models.py` 或搜索逻辑前先读 `server/README.md`。不变量：

- 明文密码绝不发给 AI 服务；AI 只见脱敏元数据（URL、用户名、备注、密码形态）。
- 密码三重存储：`encrypted_password`（可逆密文）、`password_hash`（Argon2id）、`password_fingerprint`（keyed HMAC-SHA256，供精确匹配搜索）。
- TOTP 种子（条目级两步验证）为机密级：服务器仅以 `totp_encrypted`（Fernet 密文）存储，不存 hash/指纹；绝不进入 `fields_json`、备注、AI 上下文或 MCP 输出。验证码只在客户端生成——服务器永不生成或校验。`pasted_text` 在解析前会被清洗掉 `otpauth://`（服务端将其路由到加密列）。
- `permissions_json`（条目级矩阵：只读 / 隐藏密码 / 二次确认 / AI 访问级 `none|metadata|metadata_and_tools`）为非机密元数据。在服务器具备真实认证前，执行在客户端 + MCP 端；`aiAccess=none` 在 MCP 中必须与「条目不存在」不可区分。
- 搜索两种模式：语义匹配（描述/标签），以及查询即原密码时的 keyed-hash 精确匹配。

不得在 Swift 客户端（`SecretBoxAPI.swift`）或服务器中削弱或绕过这些边界。

## 当前优先级

iOS 先行——见 `ROADMAP.md`（阶段 0 / MP / 1 / MB（macOS 菜单栏优化）已完成；下一步是阶段 2：联调与认证）。

## 约定

- Swift 应用使用单一 xcodeproj；新源码文件必须加入工程/目标（应用代码不用 SPM）。
- 服务器为 Python 3，`from __future__ import annotations` 风格，FastAPI 经 `get_db` 依赖注入。
- 样本数据 / 分类器夹具：`server/docs/diverse_fifty_samples.json`（macOS 样本集回归测试使用）。
- 许可：AGPL-3.0 + 商业双许可（见 `README.md`）。提交贡献即授权项目以 AGPL-3.0 与项目商业许可双重发布。
