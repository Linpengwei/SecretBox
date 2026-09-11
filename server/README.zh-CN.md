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

记录载荷接受 `totp`（`secret` base32 + `digits` 6–8 + `period` 15–120 + `algorithm` SHA1/SHA256/SHA512；非法返回 422）与 `permissions`。更新时缺省 `totp` 表示保留种子，`remove_totp: true` 表示清除；search/create/update 响应携带解密后的种子载荷与权限，客户端据此在本地生成验证码。

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
