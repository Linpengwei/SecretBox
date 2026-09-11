# 人格化密码使用场景测试集（persona-200）

用 **claude / codex / opencode** 三个 AI CLI 分别模拟 6 类人群共 **200 个**密码使用场景，
作为 SecretBox 的稳定性回归测试集，观测不同人群使用该软件的效果。

## 人群与生成器分工（200 条）

| 人群 | 条数 | 生成 CLI | 场景特征 |
| --- | --- | --- | --- |
| 专业 SRE | 40 | claude | redis/database/kafka/S3/AK-SK 连接串与 kv 粘贴，prod/staging 混杂，简短技术词检索 |
| 软件开发工程师 | 30 | claude | .env 片段、DATABASE_URL、假 token、本地/staging 服务，口语化检索 |
| 产品经理 | 30 | codex | 后台/管理台账号、BI 只读库、API 密钥，完整自然句检索 |
| 设计师 | 35 | codex | 设计工具账号、字体授权码、素材桶，随性带 emoji 的检索 |
| 电脑小白 | 40 | opencode | 凌乱粘贴、裸密码手输、中文/emoji/弱密码，记忆碎片式检索 |
| 行政/财务人员 | 25 | opencode | OA/报销/考勤/打印机等办公系统，礼貌完整句检索 |

## 目录结构

- `prompts/*.md` — 6 份人群生成提示词（可复现，含类型分布与安全硬性规则）
- `generate.sh` — 并行调用三个 CLI 生成 6 个批次，原始输出落盘 `raw/`
- `raw/` — 各 CLI 原始输出（含 `.err` 日志），用于审计
- `validate_merge.py` — 校验（schema/去重/虚构域名/密码卫生）并合并为 `scenarios_200.json`
- `scenarios_200.json` — 最终测试集（200 条可执行场景）
- `results_200.json` / `report.md` — 最近一次执行的结果与稳定性报告（由执行器产出）

## 场景 schema

每条场景直接映射到 SecretBox 服务端 API 的真实用户操作：

```json
{
  "id": "SRE-001",
  "generator": "claude",
  "persona": "sre",
  "title": "…", "story": "…", "difficulty": "easy|medium|hard",
  "create": { "pasted_text": "…", "primary_secret": null, "name": null, "tags": [], … },
  "expect": {
    "primary_secret": "必须原样取回的密码",
    "template_type": "redis|database|s3|kafka|aksk|account|custom",
    "semantic_query": "该人群日后会输入的检索词",
    "semantic_top_n": 5
  }
}
```

## 执行

```bash
# 1. 重新生成（可选；需要本机 claude/codex/opencode 已登录）
./testsets/persona200/generate.sh

# 2. 校验合并
python3 testsets/persona200/validate_merge.py

# 3. 执行 200 场景套件并产出报告
python3 server/scripts/run_persona_suite.py
```

执行器以进程内 TestClient 运行服务端应用，使用一次性 SQLite 库（不触碰 `secretbox.db`），
不配置外部 AI provider，因此走的是服务端确定性启发式路径，结果可复现。
注：claude CLI 走的第三方网关对默认模型映射当前返回 400，`generate.sh` 已改用
`--model deepseek-v4-flash-0731`（`~/.claude/settings.json` 中可用的映射）。

## 最近一次实测结果（2026-09-07，启发式路径，两轮运行数字完全一致）

| 维度 | 结果 | 说明 |
| --- | --- | --- |
| create | 200/200 | 全部入库（含手动补密码重试路径） |
| 粘贴即存 | 186/200 | 纯粘贴一次成功；小白从 0/40 提升到 40/40，行政 0/25 → 25/25 |
| secret_roundtrip | 194/200 | 存入的密码与用户以为的一致 |
| template_type | 183/200 | 中文标记识别后从 66% 提升到 91.5% |
| exact_search | 195/200 | 指纹机制本身全中，失败均系上游解析偏差 |
| semantic_search | 166/200 | 无 AI provider 的离线启发式下 83% |

以上六项成功率均 ≥80%（本轮优化目标）；同一代码重复运行结果逐条一致（确定性）。

## 服务端已落地的优化（server/app/ai.py、main.py）

1. **中文粘贴解析**：kv 解析支持中文键名（密码/口令/账号/用户名/网址/数据库…、
   授权码/提取码/卡密等）、全角冒号/等号、自然语句（"密码是 xxx""初始密码 X"），
   新增裸密码粘贴与两词式"站点名 + 凭据"识别，粘贴直存率 38% → 93%。
2. **URI 密码抽取修复**：空用户名 URI（`redis://:pwd@host`）不再吞前导冒号；
   URI 内嵌密码按 URL 语义百分号解码（`.env` 等字面量不受影响，仓库测试期望已同步）；
   `password=x&ssl=true` 在 `&` 处截断；多账号粘贴采用 first-wins。
3. **分类器中文标记**：账号类（网站/登录/账号/用户名/平台/地址）、aksk（access_key_id
   配对、AccessKey 单独出现）、database（数据库）、s3（存储桶/对象存储），并与
   `docs/diverse_fifty_samples.json` 的 50 样本分类约定保持零分歧。
4. **语义检索**（无 provider 的离线路径）：召回阶段把查询分词（拉丁词 + 中文二元组、
   停用字过滤）逐词 OR 匹配；候选池上限提到 200（原 60 会按 rowid 截掉目标）；
   重排按 token 稀缺度 IDF 加权（出现率 >50% 的通用词近乎置零），标题/描述/元数据分档计分，
   平局按插入序稳定排序。语义命中率 5.5% → 83%。
5. **标题派生**：粘贴中的 `名称：xxx` 行作为用户业务名直接成为条目标题。

## 遗留边界（离线启发式的极限，需配置 AI provider 解决）

- 跨语言别名：用户用中文业务名检索英文记录（"增长后台" vs `growth-admin`、
  "订单流" vs `order-stream`）无法靠词面匹配命中 —— 配置 provider 后走 LLM 重排可解。
- 共享库歧义：同类条目多时（多个"XX只读库"），口语化查询的 top5 之争本质是别名消解问题。
- 产品经理人群语义检索 19/30(63%) 即由此构成；其余人群全部单元格 ≥80%。

## 历史基线（优化前首轮，供对照）

| 维度 | 优化前 | 优化后 |
| --- | --- | --- |
| 粘贴即存 | 76/200 (38%) | 186/200 (93%) |
| create | 200/200 | 200/200 |
| secret_roundtrip | 189/200 (94.5%) | 194/200 (97%) |
| template_type | 132/200 (66%) | 183/200 (91.5%) |
| exact_search | 190/200 (95%) | 195/200 (97.5%) |
| semantic_search | 11/200 (5.5%) | 166/200 (83%) |

## 关键发现（供 ROADMAP 参考）

1. **中文粘贴曾是最大的人群鸿沟**（已修复）：此前 kv 解析只认英文键名和半角冒号，
   小白/行政人群 100% 需要手动补密码才能入库。
2. **URI 解析缺陷集中在 11 条 roundtrip 失败**（已修复）：空用户名 redis URI 前导冒号、
   jdbc `password=` 吃进查询参数、`%40` 不解码、多账号粘贴取错条。
3. **精确指纹检索不变量稳固**：只要存入密码 == 检索密码，命中率为 100%
   （`exact secret fingerprint match`）。历史上所有 exact 失败均系解析偏差。
4. **无 AI provider 时语义检索存在跨语言边界**：词面匹配无法做"增长后台↔growth-admin"
   这类别名翻译；分词 + IDF 重排已把命中做到 83%，剩余为本质歧义/跨语言案例。
5. **召回截断是隐形杀手**：候选池 `.limit(60)` 曾按 rowid 把目标记录挡在重排之外
   （评分再准也无用），此类"召回截断"问题值得在 provider 路径同样复查。
6. 延迟无问题：进程内 create 均值 ~50ms、search 均值 ~2ms（p95 2.6ms）。

## 检查维度（对应安全/可用性不变量）

1. **create** — 用户粘贴/录入能成功入库
2. **paste_parse** — 纯粘贴（不手动补密码）一次入库的成功率
3. **secret_roundtrip** — 密文可逆，原样取回密码（`encrypted_password` 不变量）
4. **template_type** — 类型分类符合该粘贴内容的预期（custom ≡ 服务端未识别模板/None）
5. **exact_search** — 拿原始密码搜索必须命中（keyed-HMAC 指纹精确匹配不变量，安全模型核心）
6. **semantic_search** — 按人群口吻的自然语言检索命中并排进 top N（可用性）

测试集数据全部为虚构合成值（主机名限定 `*.internal`/`example.*`/`*.test`），
不含任何真实凭据；断言只经由公开 API，不绕过或削弱 `server/README.md` 中的安全边界。
