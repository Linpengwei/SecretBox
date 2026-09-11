你在为密码管理工具 SecretBox 的服务端生成一份合成回归测试集。只输出一个 JSON 数组（恰好 30 个对象），不要 markdown 代码块围栏，不要任何解释文字。

# 你要模拟的人群：产品经理（30 条）
- 不太懂技术细节，保存的多是各类后台/管理台的登录账号、BI 只读数据库、API 文档密钥、数据样例桶。
- 保存方式：从聊天记录/邮件里复制 "网址 + 账号 + 密码" 的混合文本，或手动填写名称和密码。
- 搜索风格：完整自然句、用业务名而非技术名，例如 "增长后台的登录密码"、"数据看板只读账号那个"。

# 每个对象的字段（严格遵守）
{
  "title": "简短中文标题",
  "story": "一句话场景描述（第一人称、产品经理口吻）",
  "difficulty": "easy|medium|hard",
  "create": {
    "pasted_text": "用户粘贴/输入的原始文本（必须非空；像从聊天记录复制的：网址 account: 密码: 混在一行或几行）",
    "primary_secret": null,
    "name": null,
    "notes": null,
    "tags": ["最多 3 个小写标签"],
    "fields": []
  },
  "expect": {
    "primary_secret": "入库后必须能原样取回的密码（与粘贴内容中应识别出的那个密码完全一致；长度 6~48；不含换行；首尾不得有空格）",
    "template_type": "redis|database|s3|kafka|aksk|account|custom 之一",
    "semantic_query": "该产品经理日后输入的检索词（完整自然句或口语短语；不得包含密码本身；必须包含粘贴文本或 name 中出现过的业务名/账号名等特征词）",
    "semantic_top_n": 5
  }
}

# template_type 判断规则
postgres/mysql/clickhouse 等 → database；s3/bucket/aws_access_key_id → s3；kafka → kafka；access_key+secret_key → aksk；github/gitlab/slack/account/login/email/网址登录 → account；完全无特征 → custom。

# 硬性规则
- 全部数据必须虚构：网址只能用 example.com/org/net、*.internal、*.test；不得出现真实产品名对应的真实网址、真实密钥、真实邮箱、真实个人信息。内部系统可以虚构名字（如 "飞鲸数据后台"、"增长分析平台"）。
- 密码一律是明显的合成测试值（建议含 20xx 年份或公司虚构名缩写），30 条内密码和粘贴文本都不得重复。
- 约 1/3 的场景让用户手动填 name 和/或 primary_secret（模拟在界面上手动录入）。

# 30 条的类型分布（必须遵守）
- account ×16：内部后台登录 8、第三方数据工具 4、VPN/跳板 2、邮箱账号 2
- custom ×6：API 文档密钥 2、wifi 密码 2、软件license 2
- database ×3：BI 只读库 2、报表库 1
- s3 ×2：数据样例桶 1、报告存档桶 1
- kafka ×2：数据组给的 topic 看板权限 2
- aksk ×1
难度分布：easy 12、medium 13、hard 5（hard 示例：聊天记录里两条相似系统的账号贴在一起、密码含中文标点）。
