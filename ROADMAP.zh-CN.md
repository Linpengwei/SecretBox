[English](ROADMAP.md) · **简体中文**

# SecretBox Roadmap

2026-11-25 架构评审后重新规划。评审的结论是：项目一直在"加面"——面板、AI 网关、菜单栏、一个 MAUI 客户端——快过它夯实地基的速度。驱动这份计划的三个结构性问题：

1. **大多数用户走的那条路恰恰是最弱的。** 应用里的本地捕获是默认路径，而它在 200 场景语料上取到正确密码的比例只有 32%（服务端解析器：97%）。它还按字典顺序挑集群，所以同一段粘贴在不同次启动里被归到不同的集群。捕获逻辑存在三份（Swift、Python、C#），服务端解析器的修复从未移植回客户端。
2. **"明文绝不到达 AI 服务"只对被测过的输入成立。** 多密钥粘贴、百分号编码的 URI 密码、一整块 `.env` 都曾到达模型。
3. **服务器没有认证，而"server mode"已经是一个半成品的同步**——只写不拉、搜索走服务端、删除只删本地。

下面的阶段先修地基。早期阶段（iOS 编译、MFA 与权限、iOS 可用性、菜单栏）保留在文末作为历史。

## 决定（2026-11-25）

- **MAUI 冻结并标记为实验性。** 不加新功能；只让它的安全默认与 SwiftUI 应用保持一致。等阶段 5 的本地 broker 协议稳定之后，再重新考虑 Windows/Android。
- **端到端加密从只加密密钥开始。** 密码、TOTP 种子和隐藏字段在客户端加密；元数据对服务器保持可读，这样语义搜索和面板不必推倒重来。全量零知识是之后的决定。
- **agent 取密默认每次都需要批准**，可以选择按"agent + 记录"记住。
- **首批用户：带运维凭据的 SRE 与开发者。** 自动填充这类日常账号的便利放到阶段 6。

## 计划总览

| 阶段 | 主题 | 单人粗估 | 依赖 |
|---|---|---|---|
| 0 | 止血 | ~1 周 | — |
| 1 | 统一捕获引擎 | ~2 周 | — |
| 2 | 锁屏与本地安全基线 | ~1.5 周 | 可与 1 并行 |
| 3 | 账户、多租户、服务端加固 | ~2–3 周 | 0 |
| 4 | 端到端加密与同步 | ~3–4 周 | 1、2、3 |
| 5 | Agent 访问 2.0 | ~2–3 周 | 2、3 |
| 6 | 上产品 | 持续 | 3 |

旧路线图的"阶段 2"对应这里的阶段 3 和 4；旧"阶段 3"的各项去向如下：密钥治理与 `DELETE` 接口进阶段 3，iOS 发布准备进阶段 6。

## 阶段 0——止血（已完成，2026-11-25）

**服务端**

- 搜索绝不再兜底返回无关记录；无命中的查询返回空。
- AI 出口是白名单（`AI_METADATA_FIELD_KEYS`，有测试保证它与 MCP 服务器的清单完全一致）。原始 `pasted_text` 与 `source_excerpt` 绝不进入 prompt；模型输出在写回时被过滤。
- 由粘贴派生的自由文本在入库前被清洗——URI userinfo、机密级 `key: value`、自然语句里的密钥短语、已知密钥的各种编码形态——URL 字段绝不携带凭据。机密级的字段键名会被标记 `hidden`。
- 形似粘贴凭据的查询在本地排序，绝不发给模型。
- API 视图不再包含 `password_hash` 与 `password_fingerprint`。
- compose 只发布在 `127.0.0.1`；容器以非特权用户运行并带健康检查。
- 没带 `SECRETBOX_DEV=1` 时拒绝在内置开发密钥上启动；每次启动都按当前的字段规则重新清洗已存储的记录。
- 默认拒绝跨域浏览器读取（之前是 `allow_origins=["*"]`，任何网页都能读取会返回明文的 `/api/search`）。
- 上游 URL 经过校验（拒绝元数据、链路本地和隧道写法的目标）；AI 网关与审计写入有限流；请求体上限 1 MiB；面板带有一份按哈希锁定自身内联脚本的 CSP。

**客户端**

- UI 测试不再触碰真实的保险库和偏好设置：UI 测试启动时拿到的是内存保险库和私有偏好套件，测试钩子只存在于 Debug 构建。在此之前，每次 UI 测试启动都会清空真实的 Keychain 条目。
- 集群归属是确定性的：得分打平时按固定顺序取更具体的集群，没有可识别信号的粘贴保持未分类。
- 演示记录只在 UI 测试里可见——保险库为空的真实用户不会再看到一个假的"Prod S3 Bucket"。
- 一键"复制 AI 引用"的提权和捕获表单的"Open to AI reading"只授予 metadata；旧版 `aiReadable` 镜像是失败即关闭的。
- 密码与隐藏字段在用户主动显示前始终遮蔽；显示会遵循 `requireReauth`，保存或删除记录后重新遮蔽。
- 复制出的密码或验证码被标记为隐藏并在 30 秒后离开剪贴板，除非期间复制了别的东西。
- 客户端不再要求服务端返回 hash 与 fingerprint 字段。

**工程**

- CI（`.github/workflows/ci.yml`）：Linux 上跑服务器与 MCP 的 pytest、lint、persona-200 下限和仅供参考的依赖审计；每次 push 跑 macOS 单元测试。每夜任务跑完整的 macOS 与 iOS 脚本，仅供参考。
- `scripts/test-macos.sh` 跑每一个 UI 测试，缺一个就拒绝启动；`scripts/test.sh` 还会跑 lint、MCP 测试和 persona 下限。
- 配置了 `ruff`（`ruff.toml`），Python 侧已清零。
- 服务器测试跑在一次性数据库上（`tests/conftest.py`）。
- persona-200 套件有了质量下限（`testsets/persona200/floors.json`）。

**是如何验证的**

- 服务器 pytest：124 个通过（之前 38 个，其中 1 个在上一个提交上本来就不通过，因为面板被重新设计过）。MCP pytest：34 个通过。
- persona-200，启发式路径，除了一条被纠正的假阳性之外没有变化：粘贴入库 186、密码取回 194、分类 183、语义 166（都与上一次运行相同）；精确检索 194 而不是 195——少掉的那一条命中，是被移除的兜底对一个无命中查询返回的记录。
- 容器实际构建并运行过：非特权用户、只在回环地址发布（局域网地址连接被拒）、数据目录可写、健康检查通过、不带 opt-in 时拒绝开发密钥。
- CSP 在真实浏览器里检查过：面板正常加载，注入的内联事件、内联脚本、外部脚本和跨域请求全部被拦截。
- macOS 单元测试：76 个模型测试（含 50 样本回归，在独立进程里跑了五次以排除顺序导致的偶发失败）和 10 个 TOTP 测试；8 个视图快照。
- UI 测试在同一会话里分别对这个工作树和上一个提交运行过。除了 `testMenuBarSmokeFlowCanSaveAndOpenDashboard`（它过时的断言被纠正，现在通过）之外，每个测试在两边的结果都相同。11 个 macOS UI 测试里有 7 个在两边都失败；见 `TESTING.zh-CN.md`。

**阶段 0 刻意没动的**

- 解析器行为。语料里仍有 13 个场景在纯粘贴下取不到或取错密码（全角逗号后粘住整句后续、在 `!` 处截断、`redis_auth`、`pass`、`序列号`、`secret_access_key` 这类未识别的标签）。那是阶段 1 的工作，用同一份语料来度量。
- 认证。能连上服务器的人仍然可以调用一切；回环绑定是遏制，不是修复。考虑过可选的共享 token，但放弃了：在 Docker 端口发布之后，服务器分不清回环和局域网，而只在服务端强制的 token 会让面板和应用都无法使用。
- 依赖基线。`pip-audit` 对项目依赖没有报出任何已知漏洞。最新的 FastAPI 与 SQLAlchemy 要求 Python 3.11，而本地默认解释器是 3.10——升级放到阶段 3 的服务端重构里一起做。
- MCP 服务器自己的剪贴板写入（`pbcopy`，既不标记隐藏也不清除）以及它对 Keychain 的直接访问。两者都会在阶段 5 被 broker 取代。

**遗留项，按阶段归属**

- 阶段 1：`mcp-server/fuzzy_eval.py` 会把真实 Keychain 保险库换成测试保险库，只在 `finally` 里恢复；评测必须使用专用的 `SECRETBOX_KEYCHAIN_ACCOUNT`。server 模式下应用上传的是原始 `pasted_text`，并丢弃用户在 Smart Preview 里的修正；详情页显示的是从信号派生的值，所以改过的 host 虽然保存了，显示出来却还是旧值。
- 阶段 1/2：三条 iPhone 导航流程在 macOS 上被跳过；七个 macOS UI 测试失败，需要在普通 Terminal 里跑一次才能区分是环境还是回归。
- 阶段 2：记录模型只有一个受保护的密钥槽位；`hidden` 字段在应用里被遮蔽，但存储时仍是明文。
- 阶段 3：面板通过 16 处 `innerHTML` 渲染并配有一个转义函数——在引入账户之前先审计它们并补测试；Argon2 的 `password_hash` 列只写不读。
- 随时可做：两张文档截图与应用不再一致（`vault-main.png`、`quick-capture.png`）；2% 的快照容差看不见文字层面的变化。

## 阶段 1——统一捕获引擎（下一步）

**目标。** 应用能捕获服务端解析器能捕获的东西，每次启动结果都一样，而且只有一份实现需要修改。

- 把解析与分类从 `SecretBoxAppModel` 里抽成纯函数式的、确定性的、不在主线程上的代码：`CaptureParser`（文本 → 结构化记录），并带有一个明确的"未分类"结果。
- 移植服务端解析器已经具备而客户端缺失的能力：中文键名、全角标点、自然语句、裸密码、URI 密码的百分号解码、空用户名 URI、JDBC URL，以及必须在句读处截断的取值。
- 产出结构化记录，而不是"一个密钥加一段自由文本"：每条记录多个密钥槽位，上下文由带标签的字段而不是摘要构成。
- 把两份夹具替换成一份共享的黄金语料（`testsets/capture_golden.json`：200 个场景加 50 个样本），XCTest、pytest 和 xUnit 套件共同读取。
- server 模式下应用上传结构化记录，绝不再上传原始粘贴文本；服务端解析器退出写入路径。
- 清洗后的摘要只在搜索还需要它的时候保留；去掉它之前先度量召回。
- 让 `fuzzy_eval.py` 及其它评测指向专用的 Keychain account。

**验收。** 在黄金语料上，macOS 与 iOS 应用达到不低于服务端解析器的数字——粘贴入库 ≥ 93%、密码正确 ≥ 97%——并且二十次运行产出逐字节相同的结果。服务端的 persona 下限不下降。

**必须守住。** 用户在预览里做的任何修正都不会被丢弃；任何标签下的密钥都不会以普通字段的形式存储或发给模型。

## 阶段 2——锁屏与本地安全基线

- 启动时用设备凭据（Touch ID、Apple Watch、密码）解锁，通过 Keychain 访问控制守护 vault key；可选的主密码留给之后的多设备使用；自动锁、切换器里的遮蔽、登出。
- 用随机密钥加 AES-GCM 对静态保险库加密，替换单个明文 Keychain blob；既有数据无感迁移。
- 从单 blob 迁到每条记录一行的 SQLite，作为同步引擎的底座。
- 可遮蔽的自定义字段和密码生成器。

**验收。** 冷启动必须解锁；磁盘和 Keychain 中找不到任何明文密钥；既有用户零丢失迁移。

## 阶段 3——账户、多租户、服务端加固

- 用户、会话、组织、成员；登录（Argon2 + TOTP，之后是 OIDC 与 passkey）；API token 哈希存储、可撤销、带 scope。
- 每条记录归属一个 owner 或一个组织，权限由服务器强制执行。
- `DELETE` 带回收站与 tombstone；记录增量拉取；Alembic 迁移；绝不含密钥的结构化日志；审计里的 actor 取自会话而不是可伪造的 header。
- 应用里的真实登录，替换演示登录。
- 一份书面的威胁模型：保证什么、针对谁、不保证什么。
- 依赖刷新与 Python 3.11 基线，以及面板渲染审计。

**验收。** 匿名请求得到 `401`；授权矩阵有集成测试；面板需要会话。

## 阶段 4——端到端加密与同步

- 密码、TOTP 种子与隐藏字段在客户端用逐条密钥加密；指纹由客户端用用户持有的密钥计算（现在，在搜索框里输入一个密码，只是为了算指纹就会把它的明文发给服务器）。
- 同步引擎：outbox、基于游标的拉取、逐条记录的版本号、tombstone、确定性的冲突策略。
- 强度评级与复用组由客户端计算，以结论的形式同步。
- 服务端的既有记录一次性换密上传，之后删除明文列。

**验收。** 对服务端数据库做扫描找不到任何已知的明文密钥；两台设备收敛；离线改动不丢失。

## 阶段 5——Agent 访问 2.0

- App 内的 broker（XPC 或 Unix socket）持有保险库与密钥；MCP 服务器变成带 agent 身份的瘦客户端。
- 默认每次取密都由用户批准，可按 agent 与记录记住；剪贴板由 broker 写入并清除。
- transcript 泄漏测试：脚本化的 agent 跑遍所有 MCP 工具，测试断言其输出中不出现任何密钥子串。
- 应用在沙盒中运行，App Store 由此可行；`secretbox run -- <cmd>` 把密钥注入子进程的环境变量，供终端 agent 使用。

**验收。** `security find-generic-password` 读不到任何明文；未获批准的 agent 拿不到任何字节。

## 阶段 6——上产品

Developer ID 签名与公证、TestFlight、导入器（1Password / Bitwarden / KeePass）、自动填充、泄漏检测、共享界面、条目历史。

## 暂缓

- MAUI 的功能；只做安全默认的对齐。
- 面板与 AI 网关的新功能。
- 在统一捕获引擎之外新增模板或新增解析器。
- 全量零知识（元数据也加密）。
- 同步抢在认证与加密之前上线。

## 历史——已完成的阶段（保留备查）

### 旧阶段 0：iOS 编译打通

1. 平台条件编译：
   - `SecretBoxApp.swift`：`MenuBarExtra` 场景用 `#if os(macOS)` 包裹；iOS 以主窗口为唯一入口。
   - `RecordVaultView.swift:60` 的 `NSApp.activate(ignoringOtherApps:)` 用 `#if os(macOS)` 守卫。
   - `SecretBoxAppModel.swift` 中两处 `NSPasteboard.general`（剪贴板读取/复制）抽成跨平台封装（iOS 用 `UIPasteboard`）。
2. 安装 iOS 26.2 模拟器 runtime（Xcode → Settings → Components）。
3. 新增 `scripts/test-ios.sh`：xcodebuild 以 `platform=iOS Simulator` 目的地跑单元测试；把分类器回归（50 样本）也跑一遍 iOS 目的地。

验收标准：`test-ios.sh` 全绿，macOS 三个脚本保持全绿。

### 阶段 MP：MFA 无缝两步验证 + Bitwarden 式权限管理（已完成）

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

### 旧阶段 1：iOS 可用性（已完成）

1. iPhone 小屏布局适配：
   - `VaultItemEditorView` 重构为「ScrollView 表单 + 底部固定操作栏（VStack 尾节点 + 键盘避让 + ultraThinMaterial 背景）」；标题/用户名/密码在紧凑宽度堆叠排列；`scrollDismissesKeyboard(.immediately)`；macOS 保持 760×560 与横排。
   - `SettingsView` 宽度自适应（macOS 固定 520 / iOS `maxWidth: 560`）+ ScrollView 包裹。
   - `SearchVaultView` iOS：详情推入页带 `navigationTitle`；结果/详情滚动即收起键盘；状态文案改为底部浮动胶囊（`ToolbarItem(placement: .status)` 在 iPhone 不渲染，属可用性缺陷）。
   - `RecordVaultView` 为 macOS 菜单栏卡专属，真实 iOS 不呈现（仅 UI 测试面板引用），无需适配。
   - 顺手修复存量缺陷：键盘附着时编程关闭 sheet 的竞态（`dismissEditor` 先 `resignFirstResponder`）；UI 测试 `activate` 帮助函数在 macOS 分支的自递归。
2. iOS UI 冒烟测试：`scripts/test-ios.sh` 新增第 4 步，共 7 条（登录 / 种子搜索 / 捕获面板打开 / **捕获→保存→搜索→详情→复制密码全链路** / **otpauth 捕获→实时验证码→复制** / **只读权限锁定编辑与删除** / 设置面板开关）；菜单栏 4 条测试在 iOS 经 `XCTSkip` 跳过。
3. 本地模式（Keychain 持久化）在 iOS 完整可用，不依赖服务器。

验收标准：iPhone 模拟器上可完成"粘贴捕获 → Smart Preview → 保存 → 搜索 → 复制"全流程——由 `testCaptureSaveSearchDetailCopyFlow` 自动化覆盖并通过。

### 阶段 MB：macOS 菜单栏显示与交互优化（已完成）

一次聚焦的 macOS 专项（2026-09-12），iOS 先行路线上唯一的临时偏移：

1. 面板重构（`RecordVaultView` 紧凑卡）：紧凑 header（应用标识 + 记录数 + 图标按钮打开查询界面，替代原整宽大按钮）；「捕获/检索」分段切换（AppStorage 持久化；UI 测试经 `SECRETBOX_UI_TEST_MENU_BAR_MODE` 锁定模式，保证用例密闭）；宽度 290 → 320，高度自适应。
2. 检索模式（新增）：自动聚焦搜索框，复用本地打分检索（`quickAccessResults`，上限 8 条）；↑/↓ 选择并滚动跟随；↩ 执行主操作——复制密码（纯验证器条目则复制验证码）；⌘↩ 在主窗口定位该记录（`revealRecordInDashboard`）。行内悬停操作：复制密码 / 复制验证码 / 复制 AI 引用（仅对 agent 可见的条目提供）/ 在主窗口打开。空查询显示「最近使用」（最近 5 次复制，仅持久化记录 id）；每次复制/保存有瞬时反馈胶囊。
3. 捕获模式：「保存」在未检测到密钥或 `otpauth://` 链接前保持禁用（附内联提示）；⌘↩ / ⌘S 保存；「Saved · {标题}」反馈；Smart Preview 限高 250pt 自滚动。
4. 安全红线不变：所有快捷复制先过 `requestSecretUse`（requireReauth → LAContext）；hideSecret 条目可复制、明文零显示；`aiAccess=none` 条目不提供 AI 引用入口；最近使用仅存 id。

测试：模型单元测试（打分与上限、最近去重/淘汰/重载、重认证门控、TOTP 复制、保存可用性、定位记录）；新增两份快照基线（`menu-bar-capture`、`menu-bar-search`）；新增三条 macOS UI 链路（检索→↩ 复制并断言剪贴板、检索→⌘↩ 定位、捕获→⌘↩ 保存），原有四条菜单栏测试保持兼容。

## 以后再说（backlog）

- 把 `server/docs/FREEFORM_SAMPLE_LIBRARY.md` 中的 `manual` 样本自动化，并入黄金语料。
- 更多解析器：Oracle、SQLServer、redis sentinel、DigitalOcean Spaces、JDBC——全部放在统一捕获引擎之内。
- HOTP（计数器型）、Steam TOTP、macOS 扫码。
- 把三条 iPhone 导航流程适配到 macOS 布局。
- visionOS 适配。
