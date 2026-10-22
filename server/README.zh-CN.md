[English](../README.md) · **简体中文**

# SecretBox 服务器

**[English](README.md)** · **简体中文**

## 安全模型

- 明文密码绝不发给 AI。
- 服务器数据全部存于 SQLite。
- 敏感密码字段三重存储：
  - `encrypted_password`：可逆密文，供授权取回。
  - `password_hash`：Argon2id，业界标准的慢哈希。
  - `password_fingerprint`：keyed HMAC-SHA256 指纹，供不暴露原密码的精确匹配。
- TOTP 种子（两步验证，阶段 MP）为机密级数据：
  - 仅以 `totp_encrypted`（种子载荷的 Fernet 密文）存储；不保存 hash/指纹——服务器永不校验验证码、也绝不按种子搜索；
  - 绝不进入 `fields_json`、备注或任何脱敏上下文；
  - `pasted_text` 在解析前会被清洗掉 `otpauth://` Key URI——URI 被路由到加密列（并作为该条目的种子存储），而不会流向 AI 服务。
- `permissions_json` 保存条目级权限矩阵（只读 / 隐藏密码 / 二次确认 / AI 访问级）。它与 `tags` 同级的非机密元数据，经 API 同步；在 API 具备真实认证前（路线图阶段 2），执行在客户端与 MCP 端。
- AI 只收到脱敏上下文：URL、用户名、备注、存储快照、密码形态元数据。
- 搜索两种模式：
  - 对 `description` 与标签的语义匹配
  - 查询串即原密码时的 keyed-hash 精确匹配

## 本地 Docker 运行

```bash
cd server
docker compose up --build
```

启动：

- FastAPI：`http://127.0.0.1:8000`
- SQLite：`server/data/secretbox.db`

## API 概览

- `GET /health`
- `GET /api/provider`
- `PUT /api/provider`
- `POST /api/records`
- `PUT /api/records/{record_id}`（支持 `totp`、`remove_totp`、`permissions`）
- `POST /api/search`
- `GET /api/records` —— 全量清单，含每条记录的强度评级（weak/fair/strong）、复用标记与 TOTP 状态；绝不返回明文
- `PUT /api/records/{record_id}/permissions` —— 更新条目级权限矩阵
- `GET /api/dashboard/overview` · `GET /api/dashboard/security` · `GET /api/dashboard/organization` —— 看板聚合数据与安全风险审查（弱口令/复用/长期未改）
- `GET /api/audit` · `GET /api/audit/stats` · `POST /api/audit` —— 服务端审计轨迹；ingest 端点接收 agent 上报（如 MCP 工具调用）。机密形态的 detail 键在入库时被脱敏，搜索查询文本绝不入库（精确匹配模式下查询即明文密码）
- `GET /api/ai/status` —— 客户端探测"使用服务端 AI"是否可用
- `POST /ai/v1/chat/completions` —— OpenAI 兼容 AI 网关转发；服务端附加自己的上游密钥并强制服务端配置的模型。不支持流式

记录载荷接受 `totp`（`secret` base32 + `digits` 6–8 + `period` 15–120 + `algorithm` SHA1/SHA256/SHA512；非法返回 422）与 `permissions`。更新时缺省 `totp` 表示保留种子，`remove_totp: true` 表示清除；search/create/update 响应携带解密后的种子载荷与权限，客户端据此在本地生成验证码。

## 运维看板

访问 `http://127.0.0.1:8000/dashboard`（根路径自动跳转）。单文件 UI，无外部资源，五个标签页：

- **Overview** —— 记录/AI/审计统计，类型与模板分布，高频标签，24 小时活跃度曲线
- **Records & Permissions** —— 清单与强度徽章，条目级权限矩阵编辑器（只读 / 隐藏密码 / 二次确认 / AI 访问级）
- **Security Review** —— 启发式强度评分（长度、字符集、常见密码、键盘序列、日期样式），基于密码指纹的复用分组，长期未改密码检测，TOTP 覆盖情况。明文仅在服务端内存中解密以计算结论，绝不离开进程
- **Agent Audit** —— 服务端自身与 agent（`POST /api/audit`）的事件流，支持 action/actor 过滤与小时级统计
- **AI Gateway** —— 上游 provider 配置（base URL / 密钥 / 模型）、网关状态与在线测试

## AI 网关

客户端（macOS/iOS 应用、脚本）将 OpenAI 兼容的对话请求发往 `POST /ai/v1/chat/completions`，服务端用自己存储的密钥转发到配置的上游。密钥绝不离开服务端；每次调用强制使用服务端配置的模型（客户端无法指定任意或更贵的模型）；每次调用连同 token 用量记入审计。在应用侧体现为 设置 → OpenAI-compatible provider 中的 "Use server AI gateway" 选项——`GET /api/ai/status` 报告 `enabled` 后即可勾选。

## Agent 审计上报（MCP）

MCP 服务器可将每次工具调用上报到服务端审计轨迹。通过环境变量开启（默认关闭）：

```bash
SECRETBOX_SERVER_URL=http://127.0.0.1:8000
SECRETBOX_AGENT_NAME=claude-code
```

上报为尽力而为（守护线程、2 秒超时），不含任何机密（仅 action、记录 id、结果），且 URL 经过加固（仅 http/https、拒绝链路本地/云元数据地址、拒绝重定向）。

## 灌演示数据

```bash
cd server
python3 scripts/seed_demo.py
```

创建演示条目：`redis`、`s3`、`database`、`kafka`、`account`。

## 记录定位

本应用管理各类凭据——下列运维模板与日常账号皆可：

## 自由格式样本库

- 手工测试样本：`docs/FREEFORM_SAMPLE_LIBRARY.md`
