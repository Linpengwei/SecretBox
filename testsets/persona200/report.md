# SecretBox 人格化 200 场景稳定性报告

- 生成时间：2026-09-07T11:31:12+00:00
- 套件：`/Users/liuhanze/Projects/SecretBox/testsets/persona200/scenarios_200.json`（200 条）
- 执行方式：进程内 TestClient + 一次性 SQLite 库，未配置外部 AI provider（走服务端确定性启发式路径）

## 总览

| 检查维度 | 通过 | 通过率 | 说明 |
| --- | --- | --- | --- |
| 粘贴即存 | 186/200 | 93.0% | 纯粘贴一次入库成功率（失败即真实产品中需手动补密码） |
| create | 200/200 | 100.0% | 粘贴/录入能否成功入库（含手动补密码重试） |
| secret_roundtrip | 194/200 | 97.0% | 密文可逆取回，原样取回密码 |
| template_type | 183/200 | 91.5% | 类型分类符合预期（custom ≡ 服务端未识别模板/None） |
| exact_search | 195/200 | 97.5% | 拿原密码搜索必须命中（指纹精确匹配不变量） |
| semantic_search | 166/200 | 83.0% | 按用户口吻的自然语言检索命中且排进 top N |

## 按人群

| 分组 | 场景数 | 粘贴即存 | create | roundtrip | 分类 | 精确检索 | 语义检索(≤topN) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 专业 SRE | 40 | 37/40 | 40/40 | 40/40 | 39/40 | 40/40 | 38/40 |
| 软件开发工程师 | 30 | 26/30 | 30/30 | 30/30 | 30/30 | 30/30 | 25/30 |
| 产品经理 | 30 | 25/30 | 30/30 | 30/30 | 27/30 | 30/30 | 19/30 |
| 设计师 | 35 | 33/35 | 35/35 | 35/35 | 31/35 | 35/35 | 30/35 |
| 电脑小白 | 40 | 40/40 | 40/40 | 37/40 | 36/40 | 38/40 | 33/40 |
| 行政/财务人员 | 25 | 25/25 | 25/25 | 22/25 | 20/25 | 22/25 | 21/25 |

## 按生成器

| 分组 | 场景数 | 粘贴即存 | create | roundtrip | 分类 | 精确检索 | 语义检索(≤topN) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| claude | 70 | 63/70 | 70/70 | 70/70 | 69/70 | 70/70 | 63/70 |
| codex | 65 | 58/65 | 65/65 | 65/65 | 58/65 | 65/65 | 49/65 |
| opencode | 65 | 65/65 | 65/65 | 59/65 | 56/65 | 60/65 | 54/65 |

## 按难度

| 分组 | 场景数 | 粘贴即存 | create | roundtrip | 分类 | 精确检索 | 语义检索(≤topN) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| easy | 71 | 66/71 | 71/71 | 70/71 | 70/71 | 71/71 | 58/71 |
| hard | 40 | 37/40 | 40/40 | 35/40 | 35/40 | 35/40 | 37/40 |
| medium | 89 | 83/89 | 89/89 | 89/89 | 78/89 | 89/89 | 71/89 |

## 延迟（进程内，供稳定性参考）

| 操作 | n | 平均 | p95 | 最大 |
| --- | --- | --- | --- | --- |
| create | 200 | 53.1 ms | 56.1 ms | 84.2 ms |
| search | 200 | 3.6 ms | 5.2 ms | 15.7 ms |

## 失败明细（56 条）

| 场景 | 人群 | 失败维度 | 明细 |
| --- | --- | --- | --- |
| SRE-019 备份桶 aws 密钥 | 专业 SRE | semantic_search | 语义检索排名 None (需 ≤5); |
| SRE-021 日志归档 s3 凭据 | 专业 SRE | semantic_search | 语义检索排名 None (需 ≤5); |
| SRE-038 内部工单系统账号 | 专业 SRE | template_type | 期望分类 'account', 实际 None; |
| DEVE-002 GitHub 细粒度访问 token | 软件开发工程师 | semantic_search | 语义检索排名 None (需 ≤5); |
| DEVE-019 redis 内网实例的密码 | 软件开发工程师 | semantic_search | 语义检索排名 9 (需 ≤5); |
| DEVE-020 本地 redis 的连接 url | 软件开发工程师 | semantic_search | 语义检索排名 None (需 ≤5); |
| DEVE-023 本地 redis 的 dev 密码 | 软件开发工程师 | semantic_search | 语义检索排名 None (需 ≤5); |
| DEVE-027 本地 kafka 测试的认证 | 软件开发工程师 | semantic_search | 语义检索排名 10 (需 ≤5); |
| PROD-001 增长后台账号 | 产品经理 | semantic_search | 语义检索排名 None (需 ≤5); |
| PROD-003 运营后台登录 | 产品经理 | semantic_search | 语义检索排名 None (需 ≤5); |
| PROD-008 增长管理台账号 | 产品经理 | semantic_search | 语义检索排名 None (需 ≤5); |
| PROD-009 看板只读账号 | 产品经理 | semantic_search | 语义检索排名 6 (需 ≤5); |
| PROD-010 Tableau 只读密码 | 产品经理 | template_type | 期望分类 'account', 实际 None; |
| PROD-014 跳板机账号 | 产品经理 | semantic_search | 语义检索排名 None (需 ≤5); |
| PROD-015 项目邮箱密码 | 产品经理 | semantic_search | 语义检索排名 None (需 ≤5); |
| PROD-021 试用授权码 | 产品经理 | semantic_search | 语义检索排名 6 (需 ≤5); |
| PROD-023 BI 只读库连接串 | 产品经理 | semantic_search | 语义检索排名 7 (需 ≤5); |
| PROD-024 财务 BI 只读库 | 产品经理 | template_type | 期望分类 'database', 实际 'account'; |
| PROD-025 销售 BI 双库 | 产品经理 | semantic_search | 语义检索排名 8 (需 ≤5); |
| PROD-027 样例桶访问密码 | 产品经理 | semantic_search | 语义检索排名 None (需 ≤5); |
| PROD-028 报告存档桶密钥 | 产品经理 | template_type | 期望分类 's3', 实际 None; |
| PROD-030 订单流 topic 密码 | 产品经理 | semantic_search | 语义检索排名 7 (需 ≤5); |
| DESI-002 栅格双条 | 设计师 | template_type | 期望分类 'account', 实际 'kafka'; |
| DESI-013 站点双条 | 设计师 | template_type | 期望分类 'account', 实际 'kafka'; |
| DESI-023 农场口令 | 设计师 | template_type | 期望分类 'custom', 实际 'account'; |
| DESI-024 算力码 | 设计师 | template_type | 期望分类 'custom', 实际 'account'; |
| DESI-030 素材桶 | 设计师 | semantic_search | 语义检索排名 10 (需 ≤5); |
| DESI-031 贴纸桶 | 设计师 | semantic_search | 语义检索排名 None (需 ≤5); |
| DESI-032 纹理桶 | 设计师 | semantic_search | 语义检索排名 None (需 ≤5); |
| DESI-033 备份桶 | 设计师 | semantic_search | 语义检索排名 None (需 ≤5); |
| DESI-035 资产通知 | 设计师 | semantic_search | 语义检索排名 None (需 ≤5); |
| NOVI-001 实惠购商城账号 | 电脑小白 | secret_roundtrip |  |
| NOVI-004 居家好物网登录 | 电脑小白 | secret_roundtrip, exact_search | 精确检索排名 未命中; |
| NOVI-006 老友圈账号 | 电脑小白 | semantic_search | 语义检索排名 None (需 ≤5); |
| NOVI-010 嗨剧屋账号 | 电脑小白 | semantic_search | 语义检索排名 None (需 ≤5); |
| NOVI-011 小蜜蜂邮箱登录 | 电脑小白 | semantic_search | 语义检索排名 6 (需 ≤5); |
| NOVI-012 云鸽邮邮箱 | 电脑小白 | secret_roundtrip, exact_search, semantic_search | 语义检索排名 None (需 ≤5); 精确检索排名 未命中; |
| NOVI-014 便民一站办账号 | 电脑小白 | semantic_search | 语义检索排名 None (需 ≤5); |
| NOVI-018 家里宽带初始密码 | 电脑小白 | template_type | 期望分类 'custom', 实际 'account'; |
| NOVI-020 家里宽带密码 | 电脑小白 | semantic_search | 语义检索排名 6 (需 ≤5); |
| NOVI-027 彩虹健身App密码 | 电脑小白 | template_type | 期望分类 'custom', 实际 'account'; |
| NOVI-037 老照片备份账号 | 电脑小白 | template_type | 期望分类 's3', 实际 'account'; |
| NOVI-038 kafka死信队列密码 | 电脑小白 | semantic_search | 语义检索排名 None (需 ≤5); |
| NOVI-040 对象存储SK | 电脑小白 | template_type | 期望分类 'aksk', 实际 's3'; |
| ADMI-003 行政后勤OA | 行政/财务人员 | secret_roundtrip, exact_search | 精确检索排名 未命中; |
| ADMI-010 个税汇算申报 | 行政/财务人员 | semantic_search | 语义检索排名 8 (需 ≤5); |
| ADMI-011 蓝桥企业邮箱 | 行政/财务人员 | secret_roundtrip, exact_search | 精确检索排名 未命中; |
| ADMI-015 打印机管理后台-公共 | 行政/财务人员 | template_type | 期望分类 'custom', 实际 'account'; |
| ADMI-016 二楼打印机管理 | 行政/财务人员 | template_type | 期望分类 'custom', 实际 'account'; |
| ADMI-017 会议室预约系统 | 行政/财务人员 | template_type | 期望分类 'custom', 实际 'account'; |
| ADMI-018 会议室预约-公共 | 行政/财务人员 | template_type | 期望分类 'custom', 实际 'account'; |
| ADMI-019 门禁后台 | 行政/财务人员 | template_type | 期望分类 'custom', 实际 'account'; |
| ADMI-022 发票库 | 行政/财务人员 | semantic_search | 语义检索排名 None (需 ≤5); |
| ADMI-023 凭证扫描件归档桶 | 行政/财务人员 | semantic_search | 语义检索排名 None (需 ≤5); |
| ADMI-024 财务消息推送 | 行政/财务人员 | semantic_search | 语义检索排名 None (需 ≤5); |
| ADMI-025 电子签章服务 | 行政/财务人员 | secret_roundtrip, exact_search | 精确检索排名 未命中; |
