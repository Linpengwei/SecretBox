你在为密码管理工具 SecretBox 的服务端生成一份合成回归测试集。只输出一个 JSON 数组（恰好 25 个对象），不要 markdown 代码块围栏，不要任何解释文字。

# 你要模拟的人群：行政/财务人员（25 条）
- 保存 OA、报销、考勤、打印机、共享网盘、税务申报等办公系统的账号密码，常管理公共账号。
- 保存方式：从 IT 下发的"新系统开通通知"邮件里复制、手动录入并备注。
- 搜索风格：礼貌完整句，例如 "财务报销系统 admin 账号的密码"、"打印机管理页面的那个"。

# 每个对象的字段（严格遵守）
{
  "title": "简短中文标题",
  "story": "一句话场景描述（第一人称、行政/财务口吻）",
  "difficulty": "easy|medium|hard",
  "create": {
    "pasted_text": "用户粘贴/输入的原始文本（必须非空；像开通通知邮件：系统名、地址、账号、初始密码分行列）",
    "primary_secret": null,
    "name": null,
    "notes": null,
    "tags": ["最多 3 个小写标签"],
    "fields": []
  },
  "expect": {
    "primary_secret": "入库后必须能原样取回的密码（与粘贴内容中应识别出的那个密码完全一致；长度 6~48；不含换行；首尾不得有空格）",
    "template_type": "redis|database|s3|kafka|aksk|account|custom 之一",
    "semantic_query": "该行政/财务日后输入的检索词（礼貌完整句或口语；不得包含密码本身；必须包含粘贴文本或 name 中出现过的系统名/账号名等特征词）",
    "semantic_top_n": 5
  }
}

# template_type 判断规则
账号/系统登录/login/email → account；wifi/打印机/共享盘口令/无特征 → custom；postgres/mysql → database；s3/bucket → s3；kafka → kafka；access_key+secret_key → aksk。

# 硬性规则
- 全部数据必须虚构：系统名虚构（如 "云章 OA"、"票易报"），网址只能用 example.com/org/net、*.internal、*.test；不得出现真实系统对应的真实网址、真实密钥、真实邮箱、真实个人信息。
- 密码一律是明显的合成测试值（建议含 20xx 年份或公司虚构缩写），25 条内密码和粘贴文本都不得重复；公共账号在 notes 里注明 "公共账号，勿外传" 之类。
- 约 1/3 的场景手动填 name（如 "考勤系统-公共"）。

# 25 条的类型分布（必须遵守）
- account ×14：OA 3、报销 2、考勤 2、税务/社保申报 3、企业邮箱 2、共享网盘 2
- custom ×6：打印机管理 2、会议室预约系统 2、门禁后台 1、wifi 1
- database ×2：工资核算库只读 1、发票库 1
- s3 ×1：凭证扫描件归档桶 1
- kafka ×1：财务系统消息推送 1
- aksk ×1：电子签章服务 1
难度分布：easy 10、medium 11、hard 4（hard 示例：开通通知里初始密码+首次登录改密提示混在一起、两个系统通知贴在一段）。
