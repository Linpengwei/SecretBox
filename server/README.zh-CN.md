[English](../README.md) · **简体中文**

**[English](README.md)** · **简体中文**

# SecretBox 服务器

## 开发状态——请先读这里

服务器**没有认证**。能连上它的任何人都能调用每个接口，而 `/api/search` 会返回明文。在 `ROADMAP.md` 的认证阶段落地之前，有三道措施让默认部署不至于成为开放中继：

- 只发布在 `127.0.0.1:8000`（`docker-compose.yml`）。不要在你不控制的网络上把它改绑到其它接口。
- 除非设置 `SECRETBOX_DEV=1` 表明你清楚后果，否则拒绝在内置开发密钥上启动。
- 默认拒绝跨域的浏览器读取，所以操作者浏览器里的任何网页都读不到它的响应。`SECRETBOX_CORS_ORIGINS` 是显式的白名单。

## 安全模型

**AI 出口是白名单，不是脱敏。** 模型只会收到键名在 `AI_METADATA_FIELD_KEYS`（`app/redaction.py`，有测试保证它与 MCP 服务器的 `METADATA_FIELD_KEYS` 完全一致）之内的字段，外加清洗过的名称、备注和标签。原始 `pasted_text`、`source_excerpt` 以及其它任何键名下的字段都绝不进入 prompt。模型的输出同样不可信：它提出的机密级键名会被丢弃，它返回的每个值都会被清洗。

**由粘贴派生的自由文本在入库前会被清洗**（`AIService.sanitize_free_text`）：按结构去掉 URI 的 userinfo，机密级 `key: value`（含中文键名、半角与全角分隔符）和自然语句里的密钥短语被抹掉取值，已知密钥的各种编码形态（原始、百分号编码、解码后）都被移除。这套清洗基于命名，因此只是尽力而为。绝不要让任何保证依赖于它——白名单才是硬边界。

清洗后的摘要之所以保留，是因为搜索依赖它：在 200 场景语料上，去掉它会让语义检索命中从 166 掉到 85。用结构化上下文取代它是路线图中的捕获引擎阶段。

**URL 类字段绝不携带凭据。** 每个 URL 字段都会剥掉 userinfo，任何字段都不得回显主密钥的任何编码形态。键名属于机密级的字段（如 `client_secret`、`sk`、PIN）会被标记为 `hidden`：客户端据此遮蔽，AI 白名单据此丢弃。它的值仍按原样存储——在端到端加密阶段之前，记录模型只有一个受保护的密钥槽位。

**搜索**两种模式：对 `description`、标题、标签和字段做语义匹配；查询即原密码时做 keyed-hash 精确匹配。刻意不提供"无论如何返回点什么"的兜底——结果里带明文，所以查询无命中就返回空。形似粘贴凭据的查询（单个长 token、混合多种字符类别）在本地排序，绝不发给模型。

**存储。** 密码三重存储：`encrypted_password`（可逆密文）、`password_hash`（Argon2id）、`password_fingerprint`（keyed HMAC-SHA256，供精确匹配搜索与复用检测）。API 视图绝不包含 hash 和指纹；Argon2 那一列没有任何读取方。

**TOTP 种子**（条目级两步验证）为机密级：仅以 `totp_encrypted`（种子载荷的 Fernet 密文）存储，不存 hash 或指纹——服务器永不校验验证码、也绝不按种子搜索。它绝不进入 `fields_json`、备注、任何脱敏上下文或 MCP 输出。`pasted_text` 在解析前会被清洗掉 `otpauth://` Key URI——URI 被路由到加密列，而不会流向 AI 服务。验证码只在客户端生成。

**`permissions_json`** 保存条目级权限矩阵（只读 / 隐藏密码 / 二次确认 / AI 访问级）。它是非机密元数据，在 API 具备认证之前由客户端与 MCP 服务器执行。

**请求路径守卫**（`app/hardening.py`）：

- 开发密钥：除非设置 `SECRETBOX_DEV=1` 或两个密钥都已设置，否则启动失败。
- 上游 URL：`PUT /api/provider` 拒绝非 `http`/`https` 的 URL、内嵌凭据的 URL，以及解析到链路本地、云元数据、未指定、多播或保留地址的任何目标（包括 IPv4 映射和 6to4 写法）。回环与私有网络仍然允许：自托管模型服务是受支持的上游。网关在每次转发前会重新检查已存储的 URL（仅字面量）。
- 限流（按客户端）：`POST /ai/v1/chat/completions` 每分钟 60 次（它花的是操作者的上游额度），`POST /api/audit` 每分钟 600 次（它可以灌满审计轨迹）。`SECRETBOX_RATE_LIMIT=0` 关闭限流。
- 超过 1 MiB 的请求体返回 `413`。
- 每个响应都带有 Content-Security-Policy（`default-src 'self'`；面板的内联脚本按哈希放行；`object-src`、`base-uri`、`frame-ancestors` 全部锁死）、`X-Content-Type-Options`、`X-Frame-Options` 和 `Referrer-Policy`。

**启动维护**（`app/maintenance.py`）：每次启动都会把写入路径的字段规则重新应用到已存储的记录上，让结构化清洗出现之前写入的摘要丢掉其中残留的次级密钥或百分号编码的 URI 密码。手写的备注永不被改写。这一遍是幂等的。

**这不是什么。** 仍然没有账号、没有租户、没有传输安全；非机密级字段在静态存储中仍是明文；服务器仍然能解密每一个密钥；清洗也拦不住藏在没人想到的标签下的密钥。这些属于认证与端到端加密阶段。

## 本地 Docker 运行

```bash
cd server
docker compose up --build
```

启动：

- FastAPI：`http://127.0.0.1:8000`，只发布在回环地址上，以非特权用户（uid 10001）运行
- SQLite：`server/data/secretbox.db`

在 Linux 主机上，绑定挂载的 `data/` 目录必须对 uid 10001 可写（`chown 10001:10001 data`）；macOS 的文件共享不强制这一点。

不用 Docker 裸跑：

```bash
cd server
pip install -r requirements.txt
SECRETBOX_DEV=1 python3 -m uvicorn app.main:app   # 开发密钥；配置了真实密钥后去掉该变量
```

### 配置

| 变量 | 默认值 | 用途 |
|---|---|---|
| `DATABASE_URL` | `sqlite:///./secretbox.db` | SQLite 位置（compose：`/app/data/secretbox.db`） |
| `ENCRYPTION_KEY` | 内置开发密钥 | `encrypted_password` 与 `totp_encrypted` 的 Fernet 密钥。记录与写入时使用的密钥绑定。 |
| `FINGERPRINT_KEY` | 内置开发密钥 | 精确匹配搜索与复用检测的 keyed HMAC 密钥。更改它会让已有指纹失效。 |
| `SECRETBOX_DEV` | 未设置 | `1` 表示接受内置开发密钥。 |
| `SECRETBOX_CORS_ORIGINS` | 空 | 允许发起跨域浏览器请求的来源，逗号分隔。 |
| `SECRETBOX_RATE_LIMIT` | `1` | `0` 关闭按客户端的限流。 |
| `AI_TIMEOUT_SECONDS` | `20` | enrich 与 rerank 的上游超时。 |

compose 文件带有它自己的开发密钥，与内置密钥不同：同一个 `data/` 目录在这两套设置之间不可互读。不要在已有的 `data/` 目录上更改它们。

## API 概览

- `GET /health`
- `GET /api/provider`
- `PUT /api/provider` —— 上游 URL 未通过校验时返回 `422`
- `POST /api/records`
- `PUT /api/records/{record_id}`（支持 `totp`、`remove_totp`、`permissions`）
- `POST /api/search` —— 无任何命中时返回空的 `results` 数组
- `GET /api/records` —— 全量清单，含每条记录的强度评级（weak/fair/strong）、复用标记与 TOTP 状态；绝不返回明文
- `PUT /api/records/{record_id}/permissions` —— 更新条目级权限矩阵
- `GET /api/dashboard/overview` · `GET /api/dashboard/security` · `GET /api/dashboard/organization` —— 看板聚合数据与安全风险审查（弱口令/复用/长期未改）
- `GET /api/audit` · `GET /api/audit/stats` · `POST /api/audit` —— 服务端审计轨迹；ingest 端点接收 agent 上报（如 MCP 工具调用）。机密形态的 detail 键在入库时被脱敏，搜索查询文本绝不入库（精确匹配模式下查询即明文密码）
- `GET /api/ai/status` —— 客户端探测"使用服务端 AI"是否可用
- `POST /ai/v1/chat/completions` —— OpenAI 兼容 AI 网关转发；服务端附加自己的上游密钥并强制服务端配置的模型。不支持流式；触发限流返回 `429`

记录载荷接受 `totp`（`secret` base32 + `digits` 6–8 + `period` 15–120 + `algorithm` SHA1/SHA256/SHA512；非法返回 422）与 `permissions`。更新时缺省 `totp` 表示保留种子，`remove_totp: true` 表示清除；search/create/update 响应携带解密后的种子载荷与权限，客户端据此在本地生成验证码。条目视图包含 `id`、`item_type`、`template_type`、`name`、`subtitle`、`notes`、`tags`、`fields`、`primary_secret`（按需）、`totp`、`permissions`——不含密码 hash 与指纹。

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

## 测试

```bash
cd server && python3 -m pytest tests
```

测试套件跑在一次性数据库上（`tests/conftest.py`），绝不触碰 `secretbox.db`——有若干测试会整表删除。上述红线由 `tests/test_redaction.py`（存储的自由文本与 AI 出口）和 `tests/test_hardening.py`（启动守卫、上游校验、限流、响应头）断言。

解析器与搜索质量由 persona-200 套件度量，任一头条指标低于已记录的下限即失败：

```bash
python3 server/scripts/run_persona_suite.py            # 写入 testsets/persona200/results_200.json 与 report.md
```

## 灌演示数据

```bash
cd server
python3 scripts/seed_demo.py
```

创建演示条目：`redis`、`s3`、`database`、`kafka`、`account`。

## 记录定位

本应用管理各类凭据——下列运维模板与日常账号皆可：

- `redis`
- `s3`
- `database`
- `kafka`
- `custom`

## 自由格式样本库

- 手工测试样本：`docs/FREEFORM_SAMPLE_LIBRARY.md`
