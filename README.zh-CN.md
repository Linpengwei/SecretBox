[English](README.md) · **简体中文**

# SecretBox

**AI 原生密码管理器 —— 面向企业与个人。** 凭据存一次，人和 AI agent 都能用，而明文永不进入对话、终端或模型上下文。可以理解为「AI 时代的 1Password」。

## 我们解决什么问题

AI 编程 agent 与聊天助手随时需要凭据——数据库地址、API Key、服务密码。今天的做法是把明文粘进聊天窗口、终端和配置文件，随之泄漏到日志、会话记录与厂商管道里。「让 AI agent 碰生产密钥」一直是不可逾越的红线——现在可以了。

## SecretBox 怎么解决

- **Agent 看到的是元数据，不是密钥。** 内建 MCP 服务器让 Claude Code / OpenCode / Codex 检索你的密码库、读取脱敏详情（名称/类型/主机/密码形态）；任何响应在结构上就不可能包含明文。
- **密钥走剪贴板。** 当 agent 确实需要密码或当前两步验证码时，`copy_password` / `copy_totp` 把它放到剪贴板由人来粘贴——全程不经过对话。
- **粘贴引用，而不是密钥。** 「复制 AI 引用」按钮生成一段 `<secretbox-credential id=…>`，可安全粘贴进任何聊天；agent 一次调用即可经 MCP 解析。
- **每条记录自带 AI 访问级**——禁止（默认）/ 仅元数据 / 元数据+工具。被禁止的记录与「不存在」不可区分：无元数据、无存在性泄漏。

## 底下是一套完整的密码管理器

粘贴连接串或账号片段，自动整理成结构化条目——既覆盖 redis / s3 / database / kafka / aksk 等运维模板，也覆盖日常账号——本地优先加密。密码管理器的基本盘一样不少：

- **MFA 无缝两步验证（内建验证器）**——粘贴 base32 种子或 `otpauth://` 链接（iPhone 可扫码），条目即带**30 秒实时验证码**；倒计时环即复制按钮，主窗口与菜单栏皆可用。验证码完全在设备本地生成（RFC 6238）；服务器只以密文存种子。
- **条目级细粒度权限管理**——只读锁定、隐藏密码（可用不可见）、取用密钥前生物识别二次确认、AI 访问三级控制。每个主体——无论人还是 AI agent——都按条目设防，被禁条目与「不存在」不可区分。
- **团队共享在路线图上**——Bitwarden 式集合/分组/角色（Owner / Admin / Manager / User）与按集合授权将在阶段 2 落地，并配套服务端强制执行；条目级权限结构已为此预留 subjects。

一切运行在你的设备上：SwiftUI 客户端（macOS 菜单栏 + 主窗口 / iPhone）+ 可选 FastAPI 服务器 + 零依赖 MCP 服务器。

## 截图与使用方法

### 1. 登录

启动后输入任意非空账号密码即可进入（当前为本地演示登录，真实服务器认证在路线图中）。

<img src="docs/screenshots/login.png" width="480" alt="登录页">

### 2. 密码库主窗口

主窗口三栏：左侧筛选与聚类、中间条目列表、右侧完整详情。输入关键字（host / service / env / 用户名 / 标签）点 **Search**；直接粘贴密码本身则走 keyed-hash 精确匹配。

<img src="docs/screenshots/vault-main.png" width="1200" alt="密码库主窗口与详情">

详情页展示结构化条目：聚类 Schema、识别上下文、身份、字段、密钥区，以及带两步验证条目的**实时验证码**（30 秒轮换）。点倒计时环即复制验证码，**Copy Password** 就在旁边。

### 3. 菜单栏面板（macOS）

菜单栏弹出面板把两个高频动作收进一个紧凑面板，「捕获 / 检索」切换会记住上次使用的模式：

- **捕获**——粘贴松散文本，核对 Smart Preview，**⌘↩**（或 ⌘S）保存；未检测到密钥或 `otpauth://` 链接时「保存」保持禁用，垃圾内容进不了密码库。
- **检索**——输入关键字，**↑↓** 选择，**↩** 复制密码（纯验证器条目复制当前验证码），**⌘↩** 在主窗口定位记录；空查询显示最近使用；每次复制都有瞬时确认胶囊。

<img src="docs/screenshots/menubar-panels.png" width="720" alt="macOS 菜单栏面板：捕获模式（左）与检索模式（右）">

所有快捷复制都遵循条目权限——需要生物识别二次确认的条目会先验证，对 AI 禁用的条目不会出现 AI 引用入口。

### 4. 快速捕获

点 **Quick Capture**（+ 按钮）粘贴任意松散文本——redis URI、S3 密钥对、账号片段、或含 `otpauth://` 链接的混合内容。Smart Preview 实时显示识别结果（类型/标签/字段），保存前可逐字段修正。

<img src="docs/screenshots/quick-capture.png" width="820" alt="快速捕获与智能预览">

凭据旁粘贴 `otpauth://` 链接会自动挂载 TOTP 种子（预览标注「已检测到两步验证」）；只有链接的粘贴会生成独立的验证器条目。

### 5. MFA（两步验证）与权限

任意条目点 **Edit** 下滑到底：

- **两步验证 (TOTP)**——粘贴 base32 种子或完整 `otpauth://` 链接（iPhone 可扫码），输入时实时解析预览；种子保存后不再回显。
- **权限**——条目级矩阵：只读锁定（禁编辑/删除）、隐藏密码（可用不可见）、生物识别二次确认、AI 访问三级（禁止/仅元数据/元数据+工具）。

<img src="docs/screenshots/edit-totp-permissions.png" width="820" alt="编辑器：两步验证与权限矩阵">

验证码完全在设备本地生成（RFC 6238）；服务器只保存密文种子。

### 6. 设置

服务器模式（默认关闭——本地保险箱加密存于 Keychain）、OpenAI 兼容服务配置、智能整理周期。

<img src="docs/screenshots/settings.png" width="580" alt="设置面板">

## 功能一览

**捕获与整理**
- 粘贴任意松散文本（redis/s3/database/kafka/account/aksk/custom 连接串、账号片段、中英文混排），自动解析字段、识别模板、信号聚类归档
- Smart Preview 实时预览解析结果，可逐字段修正后再保存
- 智能整理：阈值触发 + 周期性 + 手动三种模式的重聚类

**macOS 菜单栏面板**
- 快捷捕获：粘贴即解析，Smart Preview 实时核对，⌘↩ / ⌘S 保存；未识别到密钥前「保存」保持禁用
- 快捷检索：关键字 + ↑↓ / ↩ 键盘流，一键复制密码或 TOTP 验证码，⌘↩ 在主窗口定位记录；最近使用常驻一瞥可达
- 所有快捷复制先过条目权限（生物识别二次确认、AI 引用仅对可见条目出现）

**搜索**
- 语义搜索（描述/标签/字段）
- 密码精确匹配：查询即原密码时经 keyed HMAC 指纹直接命中，全程不比对明文

**MFA 无缝两步验证**（对标 Bitwarden Integrated Authenticator）
- 条目挂 TOTP 种子：粘贴 base32 种子或完整 `otpauth://` 链接，或 iOS 扫二维码；捕获文本中的 `otpauth://` 自动提取
- 详情页实时验证码：30 秒轮换 + 倒计时环，点环即复制，紧贴「复制密码」无缝衔接
- 验证码全部本地生成（RFC 6238，SHA1/256/512，6–8 位，15–120 秒周期），服务器只密文存取种子

**条目级权限矩阵**（对标 Bitwarden 细粒度访问控制）
- 只读锁定（锁编辑/删除，编辑器内解锁是唯一路径）
- 隐藏密码（可复制使用，明文与验证码永不显示）
- 生物识别二次确认（Touch ID / Face ID / 设备密码，对应 Bitwarden 主密码 re-prompt）
- AI 访问三级：禁止（默认）/ 仅元数据 / 元数据 + 剪贴板工具
- 预留的 subjects 结构将在阶段 2 成长为团队集合/分组/角色

**AI 集成**
- OpenAI 兼容 LLM 增强（模板归一、重排序），AI 只见脱敏元数据
- `mcp-server/`：零依赖 stdio MCP 服务器，Claude Code / OpenCode / Codex 可查元数据、经剪贴板取密码与验证码——明文绝不进入 agent 上下文，未授权条目对 agent 完全不可见

**本地优先**
- 默认本地模式：整库经 Keychain 加密存储，无需服务器
- 可选 Server 模式：FastAPI 同步（TOTP 种子 Fernet 密文落库）

## 快速开始

### 客户端（macOS / iPhone）

```bash
open SecretBox/SecretBox.xcodeproj   # Xcode 中选 SecretBox scheme，Cmd+R
```

iOS 需 Xcode 26+ 与 iOS 26 模拟器 runtime；本地模式开箱即用（登录为本地演示，任意非空账号密码）。

### 服务器

```bash
cd server
docker compose up --build    # http://127.0.0.1:8000
python3 scripts/seed_demo.py # 可选：灌入演示数据
```

或裸跑：`pip install -r requirements.txt && python3 -m uvicorn app.main:app`。首次启动自动建库迁移。

### MCP 服务器

见 `mcp-server/README.md`（注册进 Claude Code / OpenCode / Codex 的配置方法与安全模型）。

## 测试

```bash
./scripts/test.sh            # macOS 应用测试 + 服务器 pytest
./scripts/test-macos.sh      # macOS 全量（单元 + 50 样本回归 + UI 冒烟）
./scripts/test-ios.sh        # iOS 模拟器（单元 + 50 样本回归 + 7 条 UI 冒烟链路）
```

服务器：`cd server && python3 -m pytest tests`；MCP：`cd mcp-server && python3 -m pytest test_secretbox_mcp.py`。详见 `TESTING.md`。

## 安全模型（改动前必读）

完整定义见 `server/README.md`，要点：

- 密码三重存储：`encrypted_password`（Fernet 密文）/ `password_hash`（Argon2id）/ `password_fingerprint`（keyed HMAC，供精确搜索）
- 明文密码与 TOTP 种子**绝不**进入 AI 上下文、fields、MCP 输出；种子服务器端仅存 `totp_encrypted` 密文
- 验证码生成只在客户端；`pasted_text` 中的 `otpauth://` 在服务端强制清洗并路由到加密列
- ⚠️ **当前为开发态**：服务器无认证、`ENCRYPTION_KEY`/`FINGERPRINT_KEY` 为开发默认值——请勿直接公网部署，路线图阶段 2/3 解决（见 `ROADMAP.md`）

## 目录结构

```
SecretBox/            # SwiftUI 应用（Xcode 工程，macOS + iOS）
  SecretBox/          #   源码（视图/AppModel/TOTP 引擎/平台适配）
  SecretBoxTests/     #   单元测试 + 快照基线
  SecretBoxUITests/   #   UI 冒烟
server/               # FastAPI + SQLAlchemy + SQLite
mcp-server/           # 零依赖 stdio MCP 服务器
scripts/              # 测试/注册脚本
testsets/             # persona-200 场景套件产物
docs/screenshots/     # 由 DocsScreenshotsTests 重新生成
```

## 文档

- [ROADMAP.zh-CN.md](ROADMAP.zh-CN.md) — 阶段规划与进度（阶段 0 / MP / 1 / MB 已完成；下一步阶段 2：服务端集成与同步）
- [TESTING.zh-CN.md](TESTING.zh-CN.md) — 测试矩阵与运行方式
- [BETA_NOTES.zh-CN.md](BETA_NOTES.zh-CN.md) — 内测说明与变更记录
- [AGENTS.zh-CN.md](AGENTS.zh-CN.md) — 代码贡献约定与安全不变量
- [server/README.zh-CN.md](server/README.zh-CN.md)、[mcp-server/README.zh-CN.md](mcp-server/README.zh-CN.md) — 各组件安全模型与 API

## 许可

本项目采用**双许可**（dual licensing），你可以二选一：

- **开源许可：[GNU AGPL-3.0（仅本版本）](LICENSE)** —— 免费，个人与商用皆可使用、修改、分发，但一切基于本项目的衍生作品（包括通过网络提供服务而不分发二进制的 SaaS 形态）必须以 AGPL-3.0 向用户提供完整对应源码。
- **商业许可** —— 若不愿履行 AGPL 的开源义务（闭源修改、私有化部署、SaaS 不开源等），需获得商业授权：`<your-email@example.com>`（请替换为你的联系方式）。

说明：

- 依赖兼容性：服务器端依赖（FastAPI / SQLAlchemy / cryptography / argon2 等）均为 MIT / Apache 等宽松协议，与 AGPL 组合无冲突。
- 选择了「仅 AGPL-3.0 本版本」（而非 or-later），以便商业许可线保持可控。
- ⚠️ 未来若将 iOS/macOS 客户端上架 Apple App Store，AGPL 与 Apple 分发条款存在已知的兼容性争议（VLC 下架先例）——届时以商业许可自有 App 形式分发是最干净的路径。
