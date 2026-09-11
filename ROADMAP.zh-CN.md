[English](ROADMAP.md) · **简体中文**

# SecretBox Roadmap

当前优先级：**iOS 先行**。macOS 功能与后端能力保持现状（可回归），新阶段围绕把 iOS 端做可编译、可用、可联调展开。

基线状态（2026-08-29 核实）：

- iOS 构建当前失败：`RecordVaultView.swift` 导入 AppKit 导致编译不过；`SecretBoxApp.swift` 的 `MenuBarExtra` 是 macOS 专属 API。
- 本机 Xcode 已装 iOS 26.2 SDK，但未安装 iOS 模拟器 runtime（无任何可用 iOS 模拟器）。
- 服务端与 macOS 端功能完整（见 `server/README.md`、`TESTING.md`），认证为假登录，密钥为开发态。

基线更新（2026-09-08，阶段 MP 完成时核实）：

- 阶段 0 实质完成：`scripts/test-ios.sh` 存在且全绿（iOS 26.3 runtime + iPhone 17 模拟器）。
- 快照基建（`SnapshotLite.swift` / `ViewSnapshotTests.swift`）已加 `#if canImport(AppKit)` 门控，SecretBoxTests target 可在 iOS 构建。

## 阶段 0：iOS 编译打通

1. 平台条件编译：
   - `SecretBoxApp.swift`：`MenuBarExtra` 场景用 `#if os(macOS)` 包裹；iOS 以主窗口为唯一入口。
   - `RecordVaultView.swift:60` 的 `NSApp.activate(ignoringOtherApps:)` 用 `#if os(macOS)` 守卫。
   - `SecretBoxAppModel.swift` 中两处 `NSPasteboard.general`（剪贴板读取/复制）抽成跨平台封装（iOS 用 `UIPasteboard`）。
2. 安装 iOS 26.2 模拟器 runtime（Xcode → Settings → Components）。
3. 新增 `scripts/test-ios.sh`：xcodebuild 以 `platform=iOS Simulator` 目的地跑单元测试；把分类器回归（50 样本）也跑一遍 iOS 目的地。

验收标准：`test-ios.sh` 全绿，macOS 三个脚本保持全绿。

## 阶段 MP：MFA 无缝两步验证 + Bitwarden 式权限管理（已完成）

模仿 Bitwarden Integrated Authenticator 与细粒度访问控制，两条能力线一次落地：

**MFA（条目级 TOTP）**：

1. `TOTPEngine.swift`：RFC 6238 + RFC 4648 base32 + `otpauth://` Key URI 解析（SHA1/256/512，6–8 位，15–120s）；时钟可注入。验证码生成全部在客户端，服务器只存取种子。
2. 编辑器「两步验证」区：粘贴 base32 种子或完整 URI（实时解析预览，非法输入阻断保存）；iOS 相机扫码（macOS 手动，对齐 Bitwarden 桌面端）；种子保存后永不回显。
3. 详情页实时验证码：`TimelineView` 驱动 30 秒轮换码 + 倒计时环（复制即环），紧贴「复制密码」实现无缝衔接；`hideSecret` 下码显示为掩码。
4. 快速捕获自动识别：粘贴文本中的 `otpauth://` 自动提取挂载（Smart Preview 标注「两步验证」）；纯 URI 粘贴生成 account 型验证器条目。
5. 服务器同步：`totp_encrypted`（Fernet 密文）新列 + 迁移分支；create/update/search 三路径往返；请求级 base32/参数校验（非法 422）；`pasted_text` 中的 Key URI 服务端强制清洗并路由到加密列。

**权限管理（条目级矩阵，多用户留阶段 2）**：

1. `RecordPermissions`：`readOnly`（只读锁定）、`hideSecret`（隐藏密码：可复制不可见，对应 Bitwarden Hide Passwords）、`requireReauth`（生物识别二次确认，对应主密码 re-prompt）、`aiAccess` 三级（none/metadata/metadata_and_tools）+ `subjects` 预留结构。
2. `aiReadable` 布尔平滑升级为三级（`effectivePermissions` 兼容映射旧数据；保存时回写布尔镜像）；编辑器权限区（开关 + AI 分段选择器）；详情页 AI Access 三级 Menu。
3. 执行：readOnly 锁编辑/删除（编辑器内解锁是唯一路径）；hideSecret 明文零回显；requireReauth 经 `LAContext`（`ReauthGate` 可注入）门控密码/验证码复制。
4. MCP：三级权限生效（none = 与不存在不可区分；metadata = 仅脱敏元数据；metadata_and_tools = + `copy_password`/新增 `copy_totp`）；纯 stdlib RFC 6238，种子绝不进入 agent 上下文。
5. 服务器 `permissions_json` 同步（非机密元数据，与 fields_json 同级）；服务器端 enforcement 待阶段 2 认证后补。

安全不变量（均有测试覆盖）：种子仅存密文、绝不进 AI 上下文/MCP 输出/fields_json；验证码生成仅客户端；`aiAccess=none` 与条目不存在不可区分；hideSecret 明文零回显；迁移不破坏既有数据。

## 阶段 1：iOS 可用性（已完成）

1. iPhone 小屏布局适配：
   - `VaultItemEditorView` 重构为「ScrollView 表单 + 底部固定操作栏（VStack 尾节点 + 键盘避让 + ultraThinMaterial 背景）」；标题/用户名/密码在紧凑宽度堆叠排列；`scrollDismissesKeyboard(.immediately)`；macOS 保持 760×560 与横排。
   - `SettingsView` 宽度自适应（macOS 固定 520 / iOS `maxWidth: 560`）+ ScrollView 包裹。
   - `SearchVaultView` iOS：详情推入页带 `navigationTitle`；结果/详情滚动即收起键盘；状态文案改为底部浮动胶囊（`ToolbarItem(placement: .status)` 在 iPhone 不渲染，属可用性缺陷）。
   - `RecordVaultView` 为 macOS 菜单栏卡专属，真实 iOS 不呈现（仅 UI 测试面板引用），无需适配。
   - 顺手修复存量缺陷：键盘附着时编程关闭 sheet 的竞态（`dismissEditor` 先 `resignFirstResponder`）；UI 测试 `activate` 帮助函数在 macOS 分支的自递归。
2. iOS UI 冒烟测试：`scripts/test-ios.sh` 新增第 4 步，共 7 条（登录 / 种子搜索 / 捕获面板打开 / **捕获→保存→搜索→详情→复制密码全链路** / **otpauth 捕获→实时验证码→复制** / **只读权限锁定编辑与删除** / 设置面板开关）；菜单栏 4 条测试在 iOS 经 `XCTSkip` 跳过。
3. 本地模式（Keychain 持久化）在 iOS 完整可用，不依赖服务器。

验收标准：iPhone 模拟器上可完成"粘贴捕获 → Smart Preview → 保存 → 搜索 → 复制"全流程——由 `testCaptureSaveSearchDetailCopyFlow` 自动化覆盖并通过。

## 阶段 2：iOS 联调服务器与同步

1. iOS 网络接入：`NSLocalNetworkUsageDescription` 权限文案、ATS 例外（本地 HTTP 调试）、Settings 页填服务器地址。
2. 服务端补 `GET /api/records`（列表拉取）；客户端实现本地/远端同步与冲突策略。
3. 服务端真实认证（登录 + token），替换假登录；客户端接入。
4. 权限管理多用户升级：在 `permissions.subjects` 预留结构上引入 Bitwarden 式集合/组/角色（Owner/Admin/Manager/User）与按集合授权（只读/隐藏密码/可编辑），服务端开始强制执行权限。

## 阶段 3：生产化收尾

1. 密钥治理：`ENCRYPTION_KEY` / `FINGERPRINT_KEY` 仅环境变量注入并轮换；把 `server/secretbox.db` 与 compose 中的开发密钥移出 git。
2. 服务端补 `DELETE /api/records/{id}` 及客户端删除 UI。
3. iOS 发布准备：图标、启动屏、权限文案、TestFlight。

## 以后再说（backlog）

- 手工样本自动化：`server/docs/FREEFORM_SAMPLE_LIBRARY.md` 中 `manual` 样本进回归。
- 扩展解析器：JDBC、Oracle、SQLServer、redis sentinel、DigitalOcean Spaces 等。
- HOTP（计数器型）、Steam TOTP、macOS 扫码。
- macOS 专属增强、visionOS 适配。
