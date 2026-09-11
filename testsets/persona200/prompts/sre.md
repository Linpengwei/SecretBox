你在为密码管理工具 SecretBox 的服务端生成一份合成回归测试集。只输出一个 JSON 数组（恰好 40 个对象），不要 markdown 代码块围栏，不要任何解释文字。

# 你要模拟的人群：专业 SRE（40 条）
- 日常管理 redis / 数据库 / kafka / S3 / 各类 AK-SK，区分 prod / staging / ops 环境。
- 保存方式：直接粘贴连接串、kv 文本、`REDISCLI_AUTH=...` 命令行、.env 片段、jdbc url 等。
- 搜索风格：简短技术词、中英混合，例如 "prod kafka sasl 密码"、"order-cache redis"、"billing 库只读账号"。

# 每个对象的字段（严格遵守）
{
  "title": "简短中文标题",
  "story": "一句话场景描述（第一人称、SRE 口吻）",
  "difficulty": "easy|medium|hard",
  "create": {
    "pasted_text": "用户粘贴/输入的原始文本（必须非空；允许真实世界的凌乱：多余空行、尾部注释、多个 kv 同行等）",
    "primary_secret": null,
    "name": null,
    "notes": null,
    "tags": ["最多 3 个小写标签"],
    "fields": []
  },
  "expect": {
    "primary_secret": "入库后必须能原样取回的密码（与粘贴内容中应识别出的那个密码完全一致；长度 6~48；不含换行；首尾不得有空格）",
    "template_type": "redis|database|s3|kafka|aksk|account|custom 之一",
    "semantic_query": "该 SRE 日后在搜索框输入的检索词（不得包含密码本身；必须包含粘贴文本中出现过的至少 1 个特征词，如主机名/service 名/env/用户名/topic）",
    "semantic_top_n": 5
  }
}

# template_type 判断规则
含 redis:// 或 redis → redis；postgres/mysql/clickhouse/mongodb/oracle/jdbc: → database；s3/bucket/aws_access_key_id → s3；kafka/brokers/sasl_password/topic → kafka；access_key+secret_key 或 ak= / sk= → aksk；github/gitlab/slack/account/login/email → account；只有 amqp:// 或 rabbitmq 或完全无特征 → custom。

# 硬性规则
- 全部数据必须虚构：主机名只能用 *.internal、example.com、example.org、example.net、*.test；不得出现真实公司的密钥/token/真实邮箱/真实个人信息。AWS 之类 AK 只能用文档示例风格（如 AKIAIOSFODNN7EXAMPLE）。
- 密码一律是明显的合成测试值（建议含 20xx 年份或随机词），不得重复，不得是真实系统的口令。
- 你生成的 40 条里密码和粘贴文本都不得互相重复。
- 当粘贴文本中无法确定唯一密码时（极少），才用 create.primary_secret 手动指定。

# 40 条的类型分布（必须遵守）
- redis ×10：uri 形式 3、kv 形式 3、REDISCLI_AUTH 2、prod/staging 同主机不同 db 的易混淆对 2
- database ×8：postgres uri 2、mysql uri 2、clickhouse kv 2、mongodb uri + jdbc 各 1
- s3 ×6：aws kv 形式 3、s3_endpoint + rclone 风格 2、bucket 内联 1
- kafka ×8：sasl_password+brokers 4、topic+env 2、kafka connect 风格 2
- aksk ×4
- account ×2（如 Grafana 内部账号）
- custom ×2（如 rabbitmq amqp://、内部跳板机口令）
难度分布：easy 12、medium 20、hard 8（hard 示例：同 service 多环境并存、密码含特殊字符 # @ % 转义、uri 中密码 URL 编码）。
