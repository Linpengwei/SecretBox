[English](AGENTS.md) · **简体中文**

# SecretBox（代理工作约定）

AI 原生密码管理器，面向企业与个人——人与 AI agent 之间的密钥保险箱（明文绝不进入 agent 上下文）。内置运维模板（redis、s3、database、kafka、custom），同样覆盖日常账号。组件：

- `SecretBox/` — SwiftUI 应用（SwiftUI + AppKit 菜单栏与窗口，macOS 与 iOS），Xcode 工程位于 `SecretBox/SecretBox.xcodeproj`，源码在 `SecretBox/SecretBox/`，主题在 `SecretBox/SecretBox/Docs/AppTheme.swift`。
- `server/` — FastAPI + SQLAlchemy + SQLite 后端（`server/app/`），测试在 `server/tests/`。
- `mcp-server/` — 零依赖的 stdio MCP 服务器。
- `MAUI/` — 实验性的 Windows/Android 客户端，已冻结（见其 README）。不在其中加新功能，只保持它的安全默认与 SwiftUI 应用一致。
- `.github/workflows/` — CI（`ci.yml`，每次 push 与 PR）与仅供参考的每夜任务（`nightly.yml`，完整的 macOS 与 iOS 脚本）。

## 测试 / 构建

- `./scripts/test.sh` — 全量：macOS 应用测试、Python lint、服务器与 MCP 的 pytest、persona-200 质量下限。
- `./scripts/test-macos.sh` — macOS 回归套件（xcodebuild，scheme `SecretBox`，`platform=macOS`，derived data 在 `.derived/`）：单元测试（模型——含 50 样本分类器回归——TOTP 引擎、视图快照）以及全部 UI 测试，逐个运行并各重试一次。若有 UI 测试没列入清单，脚本会拒绝启动。
- `./scripts/test-sample-set-macos.sh` — 仅 50 样本分类器回归。
- `./scripts/test-ios.sh` — iOS 模拟器单元测试 + 50 样本回归 + 7 条 UI 冒烟链路（`platform=iOS Simulator,name=iPhone 17`，derived data 在 `.derived-ios/`）。
- 服务器测试：`cd server && python3 -m pytest tests`（依赖见 `server/requirements.txt`）。测试跑在一次性数据库上（`tests/conftest.py`）。绝不要把它指向你在意的数据库——有若干测试会整表删除。
- Lint：`ruff check .`（配置在 `ruff.toml`，CI 强制执行）。
- MCP 测试：`cd mcp-server && python3 -m pytest test_secretbox_mcp.py`。
- 本地跑服务器：`cd server && docker compose up --build` — 只发布在 `127.0.0.1:8000`，并以非特权用户运行。裸跑：`SECRETBOX_DEV=1 python3 -m uvicorn app.main:app`；不带这个变量，服务器会拒绝在内置开发密钥上启动。
- 灌演示数据：`cd server && python3 scripts/seed_demo.py`。
- 跑 macOS 套件前留出几 GB 磁盘。每次测试都会在 `.derived/Logs/Test/` 下写入几十 MB 的结果包，磁盘快满时运行会以误导性的方式失败——`xcodebuild` 以 `Trace/BPT trap` 崩溃，或者本身毫无问题的测试失败。
- 应用"打不开/点了没反应"时：多半是残留的 Xcode 调试会话把应用进程挂起了（僵尸实例占着 bundle ID，macOS 只会去"激活"它）。`./scripts/kill-stale-secretbox.sh` 一键清理；应用启动时也会自动清理这类冻结实例（见 `SecretBoxApp.reapFrozenSiblingInstances`）。从 Xcode 调试完记得 ⌘. 停止会话。

详见 `TESTING.md`；注意 macOS UI 测试在非普通 Terminal/Xcode 环境下可能报 `Sandbox restriction` / `testmanagerd` 错误。

## 安全模型（改代码前必读）

改动 `server/app/security.py`、`ai.py`、`redaction.py`、`models.py` 或搜索逻辑前先读 `server/README.md`。不变量：

- **AI 出口是白名单，不是脱敏。** 模型只会收到键名在 `AI_METADATA_FIELD_KEYS`（`server/app/redaction.py`，有测试保证它与 MCP 服务器的 `METADATA_FIELD_KEYS` 完全一致）之内的字段，外加清洗过的名称 / 备注 / 标签。原始 `pasted_text`、`source_excerpt` 以及其它任何键名下的字段都绝不进入 prompt。模型的输出同样不可信：它提出的机密级键名会被丢弃。
- 由粘贴派生的自由文本在入库前会被清洗（`AIService.sanitize_free_text`）：去掉 URI 的 userinfo，机密级 `key: value` 与自然语句里的密钥短语被抹掉取值，已知密钥的各种编码形态都被移除。这套清洗基于命名，因此只是尽力而为——绝不要让任何保证依赖于它；白名单才是硬边界。
- URL 类字段绝不携带凭据。键名属于机密级的字段会被标记为 `hidden`，客户端据此遮蔽，AI 白名单据此丢弃。
- 搜索绝不会兜底返回无关记录（结果里带明文）；形似粘贴凭据的查询在本地排序，不发给模型。
- API 视图绝不包含 `password_hash` 与 `password_fingerprint`。密码在服务端仍是三重存储（`encrypted_password`、Argon2id 的 `password_hash`、keyed HMAC 的 `password_fingerprint`）；Argon2 那一列没有任何读取方，会随认证阶段一起去掉。
- TOTP 种子（条目级两步验证）为机密级：服务器仅以 `totp_encrypted`（Fernet 密文，不存 hash/指纹）存储；绝不进入 `fields_json`、备注、AI 上下文或 MCP 输出。验证码只在客户端生成——服务器永不生成或校验。`pasted_text` 在解析前会被清洗掉 `otpauth://`（服务端将其路由到加密列）。
- `permissions_json`（条目级矩阵：只读 / 隐藏密码 / 二次确认 / AI 访问级 `none|metadata|metadata_and_tools`）为非机密元数据。在服务器具备真实认证前，执行在客户端 + MCP 端；`aiAccess=none` 在 MCP 中必须与「条目不存在」不可区分。
- 搜索两种模式：语义匹配（描述/标签），以及查询即原密码时的 keyed-hash 精确匹配。
- 客户端里，密码与隐藏字段在用户主动显示之前始终遮蔽（`displayedSecret` / `toggleSecretReveal`；显示属于一次密钥使用，会遵循 `requireReauth`）。写入剪贴板的密钥会被标记为隐藏并在 30 秒后移除。一键"复制 AI 引用"的提权只授予 metadata；工具访问是单独的显式选择。
- 测试钩子（`SECRETBOX_UI_TEST*`）只存在于 Debug 构建，永远够不到用户数据：UI 测试启动时拿到的是内存保险库和私有的偏好套件。

不得在 Swift 客户端（`SecretBoxAPI.swift`）或服务器中削弱或绕过这些边界。

## 当前优先级

阶段 0（止血）已完成。下一步是阶段 1：统一的捕获引擎——完整计划及每个阶段必须守住什么见 `ROADMAP.md`。

## 约定

- Swift 应用使用单一 xcodeproj，采用文件系统同步分组：保存进 `SecretBox/SecretBox/`（或测试目录）的文件自动属于对应目标——无需再往工程里添加（应用代码不用 SPM）。
- 服务器为 Python 3.10+，`from __future__ import annotations` 风格，FastAPI 经 `get_db` 依赖注入；Docker 镜像使用 3.12。
- 分类器夹具：50 样本清单在 `SecretBoxTests/SecretBoxAppModelTests.swift`（macOS 与 iOS 回归）；服务端解析器与搜索由 `testsets/persona200/` 对照 `testsets/persona200/floors.json` 的下限来度量。阶段 1 会把两者替换为一份共享的黄金语料。
- 绝不要针对你的真实 Keychain account 运行 `mcp-server/fuzzy_eval.py`：它会把真实保险库换成测试保险库，只在 `finally` 里恢复。做评测时请把 `SECRETBOX_KEYCHAIN_ACCOUNT` 指向专用 account。
- 每份文档都有英文/简体中文对应版本（`.zh-CN.md`），两边都要改。
- 许可：AGPL-3.0 + 商业双许可（见 `README.md`）。提交贡献即授权项目以 AGPL-3.0 与项目商业许可双重发布。
