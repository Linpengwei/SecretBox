# SecretBox macOS 内测说明（Beta 5）

- 构建日期：2026-08-29
- 产物：`beta/SecretBox-v1.0-beta5-macos.zip`（Release 配置，本机 ad-hoc 签名）
- 对应源码：main 分支工作区（含未提交的修复与新功能，见「本次变更」）

## 安装

```bash
unzip beta/SecretBox-v1.0-beta2-macos.zip -d /Applications
open /Applications/SecretBox.app
```

首次启动如遇 Gatekeeper 提示：右键 App → 打开。本包为 ad-hoc 签名，仅限内测分发，不要外传。

## 内测验收清单（请按此逐项试用）

1. **启动与登录**：应用启动进入登录页；输入任意非空用户名/密码即可进入（当前为本地演示登录，无服务端鉴权）。
2. **菜单栏快速捕获**：菜单栏钥匙图标 → 粘贴一段凭据文本（示例见 `server/docs/FREEFORM_SAMPLE_LIBRARY.md`）→ 观察 Smart Preview 字段/标签 → 保存。
3. **主窗口搜索**：Dashboard 搜索框输入 host/service/env 等关键字 → 结果列表 → 点击查看详情（Cluster Schema / Detected Context / Secret 各分区）。
4. **复制密码**：详情页 Copy Password → 粘贴验证内容一致。
5. **编辑与重聚类**：编辑记录字段（如改成 bucket + access_key 的 S3 形态）→ 保存 → 确认聚类标签变化。
6. **删除记录**：详情页底部 "Delete Record"（或编辑器内 Delete Record）→ 确认弹窗 → 记录消失且重启应用后不复现。
7. **数据安全**：`~/Library/Containers/Hendrix.SecretBox/` 下不应再有明文密码（记录已迁移至 Keychain）。
8. **AI Organize**：工具栏 wand 图标手动触发智能整理。
9. **设置**：Server 开关（默认关闭=本地模式）、Smart Organization 周期。

## 已知限制（内测阶段预期内）

- 登录为本地演示性质，无真实鉴权；服务端也未加认证。
- 删除仅作用于本机（服务器端无 DELETE 接口，已保存到服务器的副本不受影响）。
- `ENCRYPTION_KEY`/`FINGERPRINT_KEY` 为开发态默认值（仅服务器模式相关）。
- 内测请保持 Server 开关关闭（本地模式），服务器端尚未加固。

## 测试状态（2026-08-29）

| 项目 | 结果 |
|---|---|
| 单元测试（SecretBoxAppModelTests） | 41/41 通过（macOS） |
| 视图快照测试（ViewSnapshotTests，4 用例 5 基线） | 通过 |
| 50 样本分类器回归 | 通过（macOS 与 iOS 模拟器双端） |
| Release 构建 + 启动/退出 | 通过 |
| UI 自动化测试（3 条冒烟） | 本沙箱环境被拦（testmanagerd 超时），请本机验证 |

本机验证命令：

```bash
./scripts/test.sh          # macOS 应用 + 服务器 pytest
./scripts/test-macos.sh    # macOS 全量（含 UI 冒烟测试）
```

快照基线位于 `SecretBox/SecretBoxTests/__Snapshots__/`，改动界面后如差异符合预期，删除对应 PNG 重跑测试即可重新记录。

## 本次变更（Beta 1 → Beta 5）

- **AI 读取权限控制（Beta 5）**：每条记录新增"开放给 AI 读取"开关（详情页 AI Access 区块 / 捕获与编辑面板），默认关闭。MCP 服务端只服务已开放的记录：未开放记录对 agent 完全不可见（查询/列表/复制均视为不存在，不泄露存在性）。已有记录（如 REDIS order-cache）默认不开放，需在应用内手动开启。配套 21 项 MCP 测试 + 3 项模型单测 + 真实钥匙串双向矩阵验证（OpenCode agent 实测：开放记录可查可复制、未开放记录 0 结果）。
- **MCP 接入**：新增 `mcp-server/`（零依赖 stdio MCP 服务），已注册进 Claude Code 与 OpenCode（Codex CLI 本机未装，配置写法见 `mcp-server/README.md`）。agent 可查询凭据元数据，明文密码绝不进入 agent 上下文——取密码走剪贴板（`copy_password`）。配套 16 项安全单测 + 真实钥匙串端到端验证。
- **应用非沙箱化（Release）**：vault 从容器钥匙串迁到登录钥匙串，MCP/CLI 可读。此变更会使旧容器内数据（均为合成测试数据）不可见，需重新捕获。
- **移除主窗口顶栏的状态胶囊**：它形似搜索框但只是状态文字（如 "Enter a query"），无法交互，已按反馈移除；搜索功能本身不受影响。
- **Keychain 加密存储**：本地记录从 UserDefaults 明文 JSON 迁移到 Keychain（旧数据首次启动自动迁移，迁移后明文残留被清除）。
- **删除记录**：详情页与编辑器新增删除入口（带确认弹窗），本地删除即时落盘。
- **界面快照回归**：仓内 SnapshotLite 模块（GitHub 不可达无法解析 pointfree 包，网络可用后可替换），覆盖登录页亮/暗、菜单栏捕获卡、搜索三栏、Quick Capture 四个界面。
- **Debug 构建关闭 App Sandbox**（便于测试写基线）；Release 保持沙箱。
- 此前 Beta 1 变更（nonisolated deinit 崩溃修复、分类器修复、应用图标等）全部包含。

## 阶段 MP 变更（2026-09-08，MFA + 权限管理，尚未打包 beta）

- **条目级 TOTP 无缝两步验证（模仿 Bitwarden Integrated Authenticator）**：
  - 编辑器「两步验证」区：粘贴 base32 种子或完整 `otpauth://` 链接（实时解析预览；非法输入阻断保存）；iOS 可扫码（相机权限文案已配，macOS 保持手动录入）；种子保存后永不回显。
  - 详情页新增实时验证码区：30 秒轮换 6 位码 + 倒计时环（环即复制按钮，<5 秒变红），紧贴 Copy Password 实现无缝衔接。
  - 快速捕获自动识别：粘贴文本里的 `otpauth://` 自动提取为记录的验证码来源（Smart Preview 标注「已检测到两步验证」）；只有 URI 的粘贴会生成 account 型验证器条目。
  - 验证码全部在客户端本地生成（RFC 6238，CryptoKit）；服务器只存取种子。
- **服务器 TOTP 同步**：新列 `totp_encrypted`（Fernet 密文，与密码同密钥体系）；search/create/update 响应携带解密种子；`pasted_text` 中的 Key URI 在服务端强制清洗并路由到加密列（红线：种子绝不进入 AI 上下文，测试以 mock LLM 捕获请求体验证）。旧库启动时自动 `ALTER TABLE` 补列，数据无损。
- **权限管理（模仿 Bitwarden 细粒度访问控制）**：每条记录权限矩阵——只读锁定（锁编辑/删除，编辑器内解锁是唯一路径）、隐藏密码（可复制、明文永不显示，对应 Hide Passwords）、生物识别二次确认（Touch ID/Face ID/设备密码，对应主密码 re-prompt）、AI 访问三级（禁止/仅元数据/元数据+工具）。
  - 旧 `aiReadable` 布尔自动映射为三级（true → 元数据+工具）；保存时回写布尔镜像保持旧 MCP 兼容。
  - MCP 五工具：三级权限生效 + 新增 `copy_totp`（验证码进剪贴板，种子绝不进 agent 上下文）；metadata 级可见但复制工具拒绝。
  - `permissions_json` 服务器同步（非机密元数据）；服务端强制执行待阶段 2 真实认证。
- **iOS 编译修复**：`SnapshotLite.swift`/`ViewSnapshotTests.swift` 加 `#if canImport(AppKit)` 门控，SecretBoxTests target 现可在 iOS 模拟器构建运行。
- **测试基线**：服务器 38 项 pytest、MCP 29 项 pytest、macOS 单元测试（AppModel + 新增 TOTPEngineTests RFC 6238 向量）、快照 6 用例 8 基线（新增 totp-code / totp-code-masked，重录 editor-capture）、iOS 模拟器单元测试 + 50 样本回归全绿。

## 阶段 1 变更（2026-09-08，iOS 可用性，尚未打包 beta）

- **编辑器紧凑布局重构**：Quick Capture 与 Edit 表单改为「滚动表单 + 底部固定操作栏（毛玻璃背景、键盘避让）」；标题/用户名/密码在 iPhone 竖屏堆叠显示；滚动即收起键盘；macOS 维持原有 760×560 横排形态（快照基线不变）。
- **Settings 自适应**：iPhone 上不再固定 520pt 宽（此前横向溢出），并可滚动。
- **iOS 详情页**：推入页显示条目名作导航标题；状态文案（复制/保存确认）改为底部浮动胶囊——此前 `.status` 工具项在 iPhone 上根本不渲染。
- **存量缺陷修复**：键盘附着时保存关闭 sheet 的竞态（先 `resignFirstResponder`）；UI 测试焦点帮助函数在 macOS 分支的自递归缺陷（历史版本从未在 macOS 执行过所以未暴露）。
- **iOS UI 冒烟套件**：`test-ios.sh` 新增第 4 步共 7 条链路测试（登录、种子搜索、捕获面板、捕获→保存→搜索→详情→复制密码全链路、otpauth 捕获→实时验证码→复制、只读权限锁定编辑/删除、设置面板）；4 条菜单栏测试在 iOS 自动跳过。macOS 端全部 11 条 UI 测试同步通过。

## 回滚

如需回到初始状态：`git stash && git clean -fd beta/`（注意会移除未跟踪文件，谨慎执行）。
