[English](TESTING.md) · **简体中文**

# Testing

## 各套件在哪里跑

| 套件 | 每次 push（CI） | 本地 |
|---|---|---|
| 服务器 pytest | ✓ | `cd server && python3 -m pytest tests` |
| MCP 服务器 pytest | ✓ | `cd mcp-server && python3 -m pytest test_secretbox_mcp.py` |
| Lint（`ruff check .`） | ✓ | 经 `./scripts/test.sh` |
| persona-200 及质量下限 | ✓ | `python3 server/scripts/run_persona_suite.py` |
| 依赖审计（pip-audit，仅供参考） | ✓ | — |
| macOS 单元测试（模型 + TOTP 引擎） | ✓ | `./scripts/test-macos.sh` |
| macOS 视图快照 | —（基线与机器相关） | `./scripts/test-macos.sh` |
| macOS UI 测试 | 每夜，仅供参考 | `./scripts/test-macos.sh` |
| iOS 模拟器（单元 + 50 样本 + 7 条 UI 链路） | 每夜，仅供参考 | `./scripts/test-ios.sh` |

CI 在 `.github/workflows/`（`ci.yml`、`nightly.yml`）。它是阶段 0 这一轮写的，还没有真正跑过——首次 push 才能看出托管 runner 的实际表现。

## macOS 应用

```bash
./scripts/test-macos.sh
```

它做的事：

- `build-for-testing`
- 跑单元套件：`SecretBoxAppModelTests`（含 50 样本分类器回归）、`TOTPEngineTests`、`ViewSnapshotTests`
- 单独跑一遍 `testDiverseFiftySampleSetPersistAndClassify`
- 逐个跑 `SecretBoxUITests` 里的每一个 UI 测试
- macOS 自动化超时时对该 UI 测试重试一次
- 若 `SecretBoxUITests.swift` 里有测试没列入清单，拒绝启动（这份清单曾经只列了 14 个里的 3 个）

在 macOS 上运行 11 个 UI 测试，跳过 3 个：`testCaptureSaveSearchDetailCopyFlow`、`testCaptureWithOTPAuthShowsLiveCodeAndCopies`、`testReadOnlyPermissionLocksEditing` 走的是 iPhone 导航（返回按钮、滑动滚动），在 iOS 脚本里运行。

**测试隔离。** UI 测试启动（`SECRETBOX_UI_TEST=1`）时拿到的是内存保险库和私有偏好套件，测试钩子在发布构建中被编译掉。阶段 0 之前，被 UI 测试的 App 打开的是真实 Keychain 条目，并且每次启动都会清空它——已验证：被测进程带着 `SECRETBOX_UI_TEST=1` 却没有 `XCTestConfigurationFilePath`，而旧的存储选择恰恰依赖后者。改动之后，约三十次 UI 测试启动让真实保险库条目和真实偏好设置逐字节保持不变。

如果看到 `Sandbox restriction` 或 `testmanagerd.control was invalidated`，说明 App 测试被当前执行环境拦住了。请在普通的本地 Terminal 或 Xcode 里运行脚本。

另外请先退出正在运行的 SecretBox：同一 bundle ID 的第二个活动实例（比如开着的 Release 版）会干扰 XCUITest 的可访问性快照，让 UI 测试报元素匹配错误。

**留出几 GB 磁盘。** 每次测试都会在 `.derived/Logs/Test/` 下写入几十 MB 的结果包。磁盘快满时，运行会以误导性的方式失败：`xcodebuild` 以 `Trace/BPT trap` 崩溃，数据库类套件报磁盘错误，本身毫无问题的测试也会失败。

### macOS UI 测试的已知状态（2026-11-25）

11 个里有 7 个失败——在阶段 0 之前的提交上和之后完全一样，所以阶段 0 没有改变它们的结果：

- `testMenuBarPreviewCanEditAndSaveLocally`、`testMenuBarPreviewFieldOverrideCanSaveEditedHost`、`testMenuBarPreviewFieldsCanExpand` —— 它们把 `menubar.preview` 当作通用的"其它"元素查找，而紧凑面板把它暴露为滚动视图。
- `testMenuBarSearchCopiesSeededPasswordOnReturn`、`testMenuBarCaptureSavesWithCommandReturn` —— 按 ↩ / ⌘↩ 之后确认文案始终没有出现。
- `testSettingsSheetOpensAndCloses` —— 找不到工具栏的 Settings 按钮。

2026 年 9 月的记录里它们是通过的。它们现在在普通的 Terminal 或 Xcode 会话里是否仍然通过，**没有验证**：得出这些数字的那次会话无法让被测 App 保持在前台。在依赖这些区域之前请你自己跑一遍脚本。如果你那里也失败，它们就是 11 月界面改动的回归，需要修——从测试查询的元素类型和标签查起。

`testMenuBarSmokeFlowCanSaveAndOpenDashboard` 的断言是过时的（`"REDIS"`；解析器给这条记录起的标题是 `"REDIS cache.internal"`），每次都失败却被当成不稳定测试。断言已更正。

**快照容差是 2% 的像素。** 一段文案的改写或者一个密码被遮蔽，变化远小于这个比例，不会被察觉——`editor-capture` 的文案被重写之后仍然通过。把快照当作布局检查；真正重要的行为在模型层断言（例如密码遮蔽由 `displayedSecret` / `toggleSecretReveal` 的测试覆盖）。

## iOS 模拟器

```bash
./scripts/test-ios.sh
```

先确认存在 iOS 模拟器 runtime，然后在 `iPhone 17` 上：`build-for-testing` → 单元测试 → 50 样本分类器回归 → **7 条 UI 冒烟链路**（登录 / 种子搜索 / 捕获面板打开 / 捕获→保存→搜索→详情→复制密码 / otpauth 捕获→实时验证码→复制 / 只读权限锁定编辑与删除 / 设置面板开关）。菜单栏测试在 iOS 经 `XCTSkip` 跳过。快照套件（`ViewSnapshotTests` + `SnapshotLite`）仅限 macOS，在 iOS 上经 `#if canImport(AppKit)` 编译掉。

阶段 0 这一轮没有重跑这个脚本：没有足够的剩余磁盘做第二次构建。其中涉及 iOS 的改动很小（通过 `UIPasteboard.setItems` 设置剪贴板过期、详情页的显示开关），且由共用的模型测试覆盖，但模拟器这一跑仍然欠着。

UI 测试备注：带文本输入的 sheet 会在点击固定操作按钮前先收起键盘（在 `editor.scroll` 上滚动）——键盘避让动画进行期间点击会被悄悄丢掉；`focusAndType` 会重试聚焦直到键盘出现。

## 安全覆盖

- `SecretBoxTests/TOTPEngineTests.swift` —— RFC 6238 附录 B 向量（SHA1 八位组、SHA256、六位截断），base32 容错矩阵，`otpauth://` 解析矩阵（最小/完整/非法/拒绝 hotp），周期边界轮换，`secondsRemaining` 不变量。
- `SecretBoxAppModelTests.swift` —— TOTP 往返、权限持久化、只读锁、`ReauthGate` 注入、AI 访问级（旧版 `aiReadable` 镜像是失败即关闭的：仅 metadata 不置位），菜单栏快速访问，以及阶段 0 新增的：零信号与得分打平的粘贴确定性分类、UI 测试之外空保险库绝不出现演示记录、密钥在主动显示前遮蔽且门控被拒时保持遮蔽、编辑或删除记录后重新遮蔽、复制出的密钥标记为隐藏并自行清除且不覆盖之后的复制、旧版本写入的保险库 blob 仍可解码。
- `server/tests/test_redaction.py` —— 作为白名单的 AI 红线：六种真实的泄漏形态（多密钥粘贴、百分号编码的 URI 密码、`.env` 块、自然语句交接、JDBC URL、粘连的取码）断言没有任何密钥进入存储或任何 prompt；模型输出无法引入机密级字段；形似凭据的查询绝不到达模型；无命中的搜索不返回任何记录；API 视图不含 hash 与指纹；启动时重新清洗；服务器与 MCP 的白名单完全一致。
- `server/tests/test_hardening.py` —— 开发密钥需要显式选择；不安全的上游 URL 被拒绝（元数据、链路本地、隧道写法）；网关与审计写入的限流；请求体上限；CSP 按哈希锁定面板的内联脚本；默认拒绝跨域浏览器读取。
- `server/tests/test_api.py`、`test_dashboard.py` —— TOTP 仅存密文、权限往返、面板接口、审计脱敏、AI 网关契约。
- `mcp-server/test_secretbox_mcp.py` —— 三级访问解析、stdlib 生成器的 RFC 6238 向量、`copy_totp` 仅走剪贴板 + 种子红线、可选的审计上报。
- `testsets/persona200/` —— 200 个"粘贴并检索"场景；`floors.json` 保存套件不得跌破的头条指标。

## 快照基线

`SecretBoxTests/__Snapshots__/ViewSnapshotTests/`：`login-light`、`login-dark`、`editor-capture`、`menu-bar-capture`、`menu-bar-search`、`search-seeded`、`totp-code`、`totp-code-masked`，以及 `detail-secret-masked`（详情页里遮蔽的密码行）。基线缺失时会被录制并让测试失败一次；重跑即可比较。

## 文档截图

设置 `SECRETBOX_DOCS_RENDER=1` 时，`SecretBoxTests/DocsScreenshotsTests` 用确定性的演示数据（InMemoryRecordStore，仅假凭据）渲染 `docs/screenshots/*.png`。仓库里的图片是真实 App 的 Retina 截图，所以生成器默认不覆盖它们。

阶段 0 之后有两张图与应用不再一致：`vault-main.png` 里密码是明文的（现在主动显示前遮蔽），`quick-capture.png` 里"Open to AI reading"下方是旧文案。请从运行中的 App 重新截取。

## persona-200 场景套件（服务器）

跨六类人群（SRE / 开发 / 产品经理 / 设计师 / 小白 / 行政）的 200 个合成密码使用场景。以进程内方式对一次性 SQLite 库运行服务端应用：

```bash
python3 server/scripts/run_persona_suite.py
```

写入 `testsets/persona200/results_200.json` 与 `report.md`；任一头条指标低于 `testsets/persona200/floors.json` 即失败（`--no-floors` 跳过检查）。数据集 schema、生成器分工与最新发现见 `testsets/persona200/README.md`。

## 服务器测试与你的数据库

`server/tests/conftest.py` 把套件指向一次性数据库并接受开发密钥。有若干测试会整表删除；阶段 0 之前它们删的是 `server/secretbox.db`。不要用你在意的数据库去覆盖 `DATABASE_URL`。

## 全量

```bash
./scripts/test.sh
```

macOS 套件、lint、服务器与 MCP 的 pytest，以及 persona-200 下限。
