你在为密码管理工具 SecretBox 的服务端生成一份合成回归测试集。只输出一个 JSON 数组（恰好 35 个对象），不要 markdown 代码块围栏，不要任何解释文字。

# 你要模拟的人群：设计师（35 条）
- 保存设计工具类账号、素材站账号、字体授权码、素材云桶、团队 wifi 等。
- 保存方式：从"账号信息分享邮件"复制、手动录入名称+密码、粘贴素材站个人页里的密钥。
- 搜索风格：随性、可能带 emoji、口语化，例如 "素材库那个 🎨"、"字体授权的码"、"作品集网站后台"。

# 每个对象的字段（严格遵守）
{
  "title": "简短中文标题",
  "story": "一句话场景描述（第一人称、设计师口吻）",
  "difficulty": "easy|medium|hard",
  "create": {
    "pasted_text": "用户粘贴/输入的原始文本（必须非空；像分享邮件/聊天记录：网站名 + 账号 + 密码，排版随意）",
    "primary_secret": null,
    "name": null,
    "notes": null,
    "tags": ["最多 3 个小写标签"],
    "fields": []
  },
  "expect": {
    "primary_secret": "入库后必须能原样取回的密码（与粘贴内容中应识别出的那个密码完全一致；长度 6~48；不含换行；首尾不得有空格）",
    "template_type": "redis|database|s3|kafka|aksk|account|custom 之一",
    "semantic_query": "该设计师日后输入的检索词（随性口语，可含 emoji；不得包含密码本身；必须包含粘贴文本或 name 中出现过的网站名/用途等特征词）",
    "semantic_top_n": 5
  }
}

# template_type 判断规则
postgres/mysql 等 → database；s3/bucket/aws_access_key_id → s3；kafka → kafka；access_key+secret_key → aksk；github/gitlab/slack/account/login/email/网站登录 → account；授权码/wifi/无特征 → custom。

# 硬性规则
- 全部数据必须虚构：网站名虚构（如 "画格素材站"、"云渲染工坊"），网址只能用 example.com/org/net、*.internal、*.test；不得出现真实品牌对应的真实网址、真实密钥、真实邮箱、真实个人信息。
- 密码一律是明显的合成测试值，35 条内密码和粘贴文本都不得重复；允许 2~3 条密码含 emoji 或中文词（如 "Huaban@2026"、"紫罗兰★2024"）。
- 约 1/3 的场景让用户手动填 name（如 "作品集后台"）。

# 35 条的类型分布（必须遵守）
- account ×15：设计工具 6、素材站 4、作品集/个人站后台 3、团队协作工具 2
- custom ×10：字体授权码 3、素材站提取码 2、wifi 2、渲染农场口令 2、软件license 1
- aksk ×4：云渲染/CDN 的 access_key+secret_key 4
- s3 ×4：素材云桶 3、作品备份桶 1
- database ×1：官网内容库只读 1
- kafka ×1：设计资产更新通知 1
难度分布：easy 14、medium 15、hard 6（hard 示例：分享邮件里两条账号挨着、密码含 ★©® 等符号）。
