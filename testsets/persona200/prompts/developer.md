你在为密码管理工具 SecretBox 的服务端生成一份合成回归测试集。只输出一个 JSON 数组（恰好 30 个对象），不要 markdown 代码块围栏，不要任何解释文字。

# 你要模拟的人群：软件开发工程师（30 条）
- 保存本地/开发环境凭据：.env 文件片段、DATABASE_URL、github/gitlab token（假 token）、staging 服务密码、本地 redis/pg。
- 保存方式偏程序员：直接粘贴多行 .env、带注释的配置行、docker run -e 参数。
- 搜索风格：随意口语 + 技术词混合，例如 "staging 的 pg"、"那个 ghp_ 开头的 token"、"本地 redis"。

# 每个对象的字段（严格遵守）
{
  "title": "简短中文标题",
  "story": "一句话场景描述（第一人称、开发者口吻）",
  "difficulty": "easy|medium|hard",
  "create": {
    "pasted_text": "用户粘贴/输入的原始文本（必须非空；允许真实凌乱：多行 .env、注释行、export 前缀等）",
    "primary_secret": null,
    "name": null,
    "notes": null,
    "tags": ["最多 3 个小写标签"],
    "fields": []
  },
  "expect": {
    "primary_secret": "入库后必须能原样取回的密码（与粘贴内容中应识别出的那个密码完全一致；长度 6~48；不含换行；首尾不得有空格）",
    "template_type": "redis|database|s3|kafka|aksk|account|custom 之一",
    "semantic_query": "该开发者日后输入的检索词（不得包含密码本身；必须包含粘贴文本中出现过的至少 1 个特征词）",
    "semantic_top_n": 5
  }
}

# template_type 判断规则
含 redis:// 或 redis → redis；postgres/mysql/clickhouse/mongodb/oracle/jdbc: → database；s3/bucket/aws_access_key_id → s3；kafka/brokers/sasl_password/topic → kafka；access_key+secret_key 或 ak= / sk= → aksk；github/gitlab/slack/account/login/email → account；完全无特征 → custom。

# 硬性规则
- 全部数据必须虚构：主机名只能用 *.internal、localhost、127.0.0.1、example.com/org/net、*.test；不得出现真实密钥/token（github token 用 ghp_ 加随机合成串）、真实邮箱、真实个人信息。
- 密码一律是明显的合成测试值（建议含 20xx 年份或 dev 字样），30 条内密码和粘贴文本都不得重复。
- 当粘贴文本中无法确定唯一密码时（少量允许，如单行裸 token），才用 create.primary_secret 手动指定。

# 30 条的类型分布（必须遵守）
- account ×10：github/gitlab token 5、内部 CI 账号 2、docker registry 账号 2、npm token 1
- database ×8：DATABASE_URL 形式 3、kv 形式 3、jdbc 1、mongodb 1
- redis ×5：本地 2、staging uri 2、kv 1
- s3 ×3：minio/兼容 s3_endpoint 2、aws kv 1
- kafka ×2：本地测试 brokers+sasl 1、topic 1
- custom ×2：.npmrc/_auth_token 风格 1、随机脚本里的口令 1
难度分布：easy 10、medium 14、hard 6（hard 示例：多行 .env 里 5+ 个 kv、export 前缀、密码含 $ 和反引号）。
