# SecretBox

面向运维凭据的密码保险箱：一条粘贴自动整理成结构化条目，两步验证码内建生成，AI 助手按权限取用——明文永远不离开你的设备。

SwiftUI 客户端（macOS 菜单栏 + 主窗口 / iPhone）+ FastAPI 服务器 + 零依赖 MCP 服务器三件套。

## 功能一览

**捕获与整理**
- 粘贴任意松散文本（redis/s3/database/kafka/account/aksk/custom 连接串、账号片段、中英文混排），自动解析字段、识别模板、信号聚类归档
- Smart Preview 实时预览解析结果，可逐字段修正后再保存
- 智能整理：阈值触发 + 周期性 + 手动三种模式的重聚类

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
```

## 文档

- `ROADMAP.md` — 阶段规划与进度（阶段 0 / MP / 1 已完成，阶段 2 联调认证进行中）
- `TESTING.md` — 测试矩阵与运行方式
- `BETA_NOTES.md` — 内测说明与变更记录
- `AGENTS.md` — 代码贡献约定与安全不变量
- `server/README.md`、`mcp-server/README.md` — 各组件安全模型与 API

## 许可

本项目采用**双许可**（dual licensing），你可以二选一：

- **开源许可：[GNU AGPL-3.0（仅本版本）](LICENSE)** —— 免费，个人与商用皆可使用、修改、分发，但一切基于本项目的衍生作品（包括通过网络提供服务而不分发二进制的 SaaS 形态）必须以 AGPL-3.0 向用户提供完整对应源码。
- **商业许可** —— 若不愿履行 AGPL 的开源义务（闭源修改、私有化部署、SaaS 不开源等），需获得商业授权：`<your-email@example.com>`（请替换为你的联系方式）。

说明：

- 依赖兼容性：服务器端依赖（FastAPI / SQLAlchemy / cryptography / argon2 等）均为 MIT / Apache 等宽松协议，与 AGPL 组合无冲突。
- 选择了「仅 AGPL-3.0 本版本」（而非 or-later），以便商业许可线保持可控。
- ⚠️ 未来若将 iOS/macOS 客户端上架 Apple App Store，AGPL 与 Apple 分发条款存在已知的兼容性争议（VLC 下架先例）——届时以商业许可自有 App 形式分发是最干净的路径。
