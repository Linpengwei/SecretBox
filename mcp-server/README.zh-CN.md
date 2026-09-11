[English](../README.md) · **简体中文**

# SecretBox MCP Server

把 SecretBox 的密码查询能力以 MCP (Model Context Protocol) 形式接入 AI agent CLI：Claude Code / Claude Desktop、OpenAI Codex CLI、OpenCode。

## 安全模型（核心承诺）

**明文密码永远不会进入 AI agent 的上下文。TOTP 种子同样永不进入 agent 上下文（验证码也只进剪贴板）。**

**权限控制（应用内设置，服务端强制执行）**：每条记录有一个 AI 访问级别
（详情页 AI Access 菜单 / 编辑器权限区分段选择器），取值三级，默认**禁止**：

- `none`（禁止）——未开放的记录对 agent 完全不可见：搜索/列表不出现，按 id 查询与复制返回与"记录不存在"完全相同的错误（不泄露存在性）。
- `metadata`（仅元数据）——agent 可查询脱敏元数据，但 `copy_password` / `copy_totp` 拒绝服务。
- `metadata_and_tools`（元数据 + 工具）——完整能力，含剪贴板复制。

旧版布尔 `aiReadable == true` 自动映射为 `metadata_and_tools`（兼容既有 vault 数据）。
应用内改动立即落盘，对 agent 即时生效。

| 能力 | 返回给 agent 的内容 |
|---|---|
| `search_credentials(query)` | 命中记录的脱敏元数据（名称/类型/聚类/用户名/host/env/标签） |
| `list_credentials(limit)` | 全库脱敏元数据列表 |
| `get_credential(record_id)` | 脱敏元数据 + 密码形态（长度、字符类别，不含内容）+ `ai_access` 级别 |
| `copy_password(record_id)` | 仅 `{copied: true, record: ...}` 确认（需 `metadata_and_tools`） |
| `copy_totp(record_id)` | 仅 `{copied: true, record: ...}` 确认——当前 30 秒验证码进剪贴板，种子绝不出现（需 `metadata_and_tools` 且记录已配置两步验证） |

## 引用粘贴流程（复制 AI 引用按钮）

SecretBox 应用每条密码的详情页有 **"复制 AI 引用"** 按钮（详情操作区，Copy Password 旁）。
点击后剪贴板得到的是一段**引用**而非明文，直接粘贴到 AI agent CLI 对话里即可代替以前粘贴明文密码：

```
<secretbox-credential id="…" name="Redis Production" type="redis" username="default" host="r-xx.internal:6379">
Resolve with the SecretBox MCP server: get_credential(record_id="…") for redacted details, copy_password(record_id="…") to place the secret on the clipboard. The plaintext secret is intentionally not included — never ask me to paste it.
</secretbox-credential>
```

- 引用只含 `record_id` + 脱敏元数据（名称/类型/用户名/连接地址），**明文与 secret 类字段绝不写入**。
- agent 凭 `record_id` 直接调用 MCP 工具，无需模糊搜索——比用户描述"帮我找那个 redis 的密码"更快更准。
- 若该记录 AI 访问级别仍为「禁止」，按钮会先弹确认框引导开放（开放即 `metadata_and_tools`）；否则 agent 看不到这条记录，引用无法解析。
- 单元测试覆盖：引用不含明文（`testAIReferenceIdentifiesRecordWithoutPlaintext` 等，SecretBoxAppModelTests）。

- 所有响应经统一脱敏出口：密文字段白名单过滤 + **URI 内嵌凭据擦除**（`redis://user:pass@host` → `redis://user:[REDACTED]@host`，防止密码藏在 url 字段漏出）。
- 明文只经过两处：本服务进程内存、macOS 系统剪贴板。人通过粘贴取得密码——即"不进上下文，但可正常访问"。
- `passwordHash` / `passwordFingerprint` / `source_excerpt` / secret 类信号等一律不在响应中。

## 数据来源

SecretBox macOS 应用（Beta 3 起非沙箱化）把 vault 以 JSON blob 存在**登录钥匙串**：

```
service = Hendrix.SecretBox    account = localVault
```

本服务通过 `security find-generic-password -s Hendrix.SecretBox -a localVault -w` 读取。首次访问 macOS 可能弹钥匙串授权，选 **"Always Allow"**。应用未装或从未保存过记录时，工具会返回友好提示。

## 接入

一键注册（每个配置文件改动前自动备份）：

```bash
scripts/setup-mcp.sh --all                    # 所有支持的客户端
scripts/setup-mcp.sh --claude-code            # Claude Code
scripts/setup-mcp.sh --claude-desktop         # Claude Desktop
scripts/setup-mcp.sh --codex                  # Codex CLI
scripts/setup-mcp.sh --opencode               # OpenCode
scripts/setup-mcp.sh --remove --all           # 移除注册
```

手动配置等价写法：

| 客户端 | 配置 |
|---|---|
| Claude Code | `claude mcp add secretbox -- python3 <repo>/mcp-server/secretbox_mcp.py` |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` → `{"mcpServers":{"secretbox":{"command":"python3","args":["<repo>/mcp-server/secretbox_mcp.py"]}}}` |
| Codex CLI | `~/.codex/config.toml` → `[mcp_servers.secretbox]` `command = "python3"` `args = ["<repo>/mcp-server/secretbox_mcp.py"]` |
| OpenCode | `~/.config/opencode/opencode.json` → `{"mcp":{"secretbox":{"type":"local","command":["python3","<repo>/mcp-server/secretbox_mcp.py"],"enabled":true}}}` |

零第三方依赖（纯 Python 3 标准库），stdio 传输，客户端配置即插即用。

## 模糊需求评测

```bash
python3 mcp-server/fuzzy_eval.py            # 构建测试库 → 5 条口语化指令 → 评分 → 还原
python3 mcp-server/fuzzy_eval.py --keep-vault
```

用真实 agent（OpenCode）验证模糊表述下能否找到正确密码：正确性、剪贴板内容、
权限过滤（被拒记录即使口语描述也返回 0 结果）、transcript 无明文、逐场景耗时。
2026-09 实测 5/5 通过，平均 55.9s/场景（含 agent 推理；工具本身延迟见下节）。

## 延迟基准

```bash
python3 mcp-server/bench_tools.py --real --sizes 50 200 1000 --iterations 10
```

实测（M 系列本机，2026-09）：每个工具调用的固定成本是 `security` 子进程约 21ms；
权限过滤（aiReadable）本身在 1000 条记录时也只花 0.06ms——**几乎为零**；
脱敏+scrub 在 1000 条时约 11ms。端到端：真实库（2 条）全工具 20-35ms，
1000 条记录时 65-80ms。`copy_password` 额外多一次 pbcopy 子进程（约 +11ms）。

## 测试

```bash
python3 -m pytest mcp-server/test_secretbox_mcp.py   # 16 项协议 + 安全测试
```

端到端（真实钥匙串条目 + 真实子进程）在 CI 外手动验证通过：search 响应不含明文、URL 凭据被擦除、copy_password 后 `pbpaste` 等于真实密码而响应中只有确认。

## 依赖的存储前提

vault Keychain 条目必须位于登录钥匙串（应用非沙箱化后即如此）。若你在旧沙箱版本中保存过记录，那些数据留在应用容器里，新版本读取不到——重新粘贴捕获即可。
