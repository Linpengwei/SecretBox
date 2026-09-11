from __future__ import annotations

import json
import re
from dataclasses import dataclass
from urllib.parse import unquote, urlparse

import httpx

from .config import settings
from .models import ProviderConfig, VaultRecord
from .schemas import VaultFieldPayload
from .security import summarize_password_shape


@dataclass(slots=True)
class EnrichedItem:
    item_type: str
    template_type: str | None
    name: str
    notes: str
    tags: list[str]
    fields: list[VaultFieldPayload]


@dataclass(slots=True)
class ParsedPastedSecret:
    item_type: str
    template_type: str | None
    primary_secret: str | None
    name: str | None
    notes: str | None
    tags: list[str]
    fields: list[VaultFieldPayload]
    redacted_excerpt: str | None


class AIService:
    SECRET_KEYS = {
        "password", "passwd", "pwd", "secret", "secret_key", "secretkey",
        "secret-key", "token", "sk", "sasl_password", "api_key", "apikey",
        "aws_secret_access_key", "rabbitmq_password", "rediscli_auth",
    }
    # Deterministic priority order for secret/username lookup; sets alone would
    # make multi-secret pastes resolve differently per process (PYTHONHASHSEED).
    SECRET_KEY_ORDER = (
        "password", "passwd", "pwd", "secret", "secret_key", "secretkey",
        "secret-key", "sasl_password", "rabbitmq_password", "rediscli_auth",
        "aws_secret_access_key", "api_key", "apikey", "token", "sk",
    )
    USERNAME_KEYS = {"username", "user", "account", "login", "email", "sasl_username", "aws_access_key_id"}
    USERNAME_KEY_ORDER = ("username", "user", "account", "login", "email", "sasl_username", "aws_access_key_id")
    URL_KEYS = {"url", "uri", "dsn", "jdbc_url", "database_url", "redis_url", "endpoint", "s3_endpoint"}

    # Chinese freeform keys -> canonical kv keys. Longest suffix wins, so
    # "wifi密码" and "管理密码" both resolve to "password".
    CHINESE_KEY_ALIASES = {
        "密码": "password", "口令": "password", "密碼": "password",
        "授权码": "password", "激活码": "password", "提取码": "password",
        "兑换码": "password", "卡密": "password", "购买码": "password",
        "秘钥": "secret_key", "密钥": "secret_key", "访问密钥": "secret_key",
        "账号": "username", "账户": "username", "帐号": "username",
        "用户名": "username", "用户": "username", "邮箱": "email",
        "网址": "url", "链接": "url", "地址": "url",
        "主机": "host", "端口": "port", "数据库": "database",
        "服务": "service", "环境": "env", "主题": "topic",
        "名称": "item_label",
    }
    # Natural-language phrases like "密码是 xxx" that carry no kv separator.
    # Ordered: a labeled Secret Key wins over an Access Key in the same paste
    # (chat-style aksk handoffs expect the SK as the primary secret).
    NL_SECRET_VALUE = r"[「『\"']?([^\s，。；;，！？\"'（）「」『』【】]+)"
    NL_SECRET_PATTERNS = (
        re.compile(r"(?:secret[\s\-]?key|secretkey|\bsk\b|密钥|秘钥)\s*[^：:=＝\n]{0,16}?(?:是|为|:|：|=|＝)\s*\s*(?:这个)?\s*(?:[→:>～—-]+\s*)?" + NL_SECRET_VALUE, re.IGNORECASE),
        re.compile(r"(?:secret[\s\-]?key|secretkey|\bsk\b|密钥|秘钥)\s*[:：=＝]\s*" + NL_SECRET_VALUE, re.IGNORECASE),
        re.compile(r"(?:passw(?:ord)?|passwd|pwd|密码|口令|密碼)\s*[^：:=＝\n]{0,16}?(?:是|为|:|：|=|＝)\s*\s*(?:这个)?\s*(?:[→:>～—-]+\s*)?" + NL_SECRET_VALUE, re.IGNORECASE),
        re.compile(r"(?:passw(?:ord)?|passwd|pwd|密码|口令|密碼)\s*[:：=＝]\s*" + NL_SECRET_VALUE, re.IGNORECASE),
        re.compile(r"(?:token|令牌)\s*[^：:=＝\n]{0,16}?(?:是|为|:|：|=|＝)\s*" + NL_SECRET_VALUE, re.IGNORECASE),
        re.compile(r"(?:access[\s\-]?key|accesskey|\bak\b)\s*[^：:=＝\n]{0,16}?(?:是|为|:|：|=|＝)\s*" + NL_SECRET_VALUE, re.IGNORECASE),
        re.compile(r"(?:购买码|授权码|激活码|提取码|兑换码|卡密|口令)\s*[^：:=＝\n]{0,16}?(?:是|为|:|：|=|＝)\s*\s*(?:这个)?\s*(?:[→:>～—-]+\s*)?" + NL_SECRET_VALUE, re.IGNORECASE),
        # keyword + bare whitespace + value ("初始密码 Xf4@Pk8#Rs2"), with the
        # colon-less novice style "密码 Sj3Ka7$Lp8"
        re.compile(r"(?:passw(?:ord)?|passwd|pwd|密码|口令|密碼|购买码|授权码|激活码|提取码|兑换码|卡密)\s+(?:她|他|它)?(?:是|为)?\s*" + NL_SECRET_VALUE, re.IGNORECASE),
        # glued value with no separator at all ("密码20010515", "账号admin")
        re.compile(r"(?:passw(?:ord)?|passwd|pwd|密码|口令|密碼|购买码|授权码|激活码|提取码|兑换码|卡密)([A-Za-z0-9][A-Za-z0-9@#$%^&*!?+_\-=]{3,})"),
    )
    # Values that are really instructions to the reader, not passwords
    # ("密码给你 收好" must not store "给你").
    NL_VALUE_STOPWORDS = {
        "给你", "给你了", "发你", "发你了", "收好", "记好", "记一下", "记住了",
        "保存好", "备份好", "别弄丢", "别外传", "尽快改", "及时修改", "你们",
        "自己连", "看好", "更新了", "修改了", "重置了", "改好了",
    }
    # Same natural-language style for non-secret keys ("账号是 pm_growth").
    NL_KV_RE = re.compile(
        r"(密码|口令|密碼|密钥|秘钥|授权码|激活码|提取码|兑换码|卡密|账号|帐号|账户|用户名|用户|邮箱|网址|链接|地址)(?:是|为)\s*[「『\"']?([^\s，。；;，！!？?\"'（()）]+)"
    )
    # kv line: key may be CJK, separators cover half/full-width colon and equals.
    # Values may legitimately contain commas (kafka brokers, host lists).
    KV_PAIR_RE = re.compile(
        r"([\u4e00-\u9fffA-Za-z_][\u4e00-\u9fffA-Za-z0-9_\-.]*?)\s*[:：=＝]\s*"
        r"(\"[^\"]+\"|'[^']+'|[^\s]+)"
    )
    URI_SCHEME_RE = re.compile(r"^[a-z][a-z0-9+.\-]*://", re.IGNORECASE)

    async def enrich_item(
        self,
        provider: ProviderConfig | None,
        item_type: str,
        template_type: str | None,
        name: str | None,
        primary_secret: str,
        pasted_text: str | None,
        notes: str | None,
        tags: list[str],
        fields: list[VaultFieldPayload],
    ) -> EnrichedItem:
        heuristic = self._heuristic_enrichment(
            item_type=item_type,
            template_type=template_type,
            name=name,
            primary_secret=primary_secret,
            pasted_text=pasted_text,
            notes=notes,
            tags=tags,
            fields=fields,
        )
        if provider is None:
            return heuristic

        payload = {
            "item_type": item_type,
            "template_type": template_type,
            "name": name,
            "notes": notes,
            "tags": tags,
            "fields": [field.model_dump(mode="json") for field in fields],
            "pasted_text": pasted_text,
            "secret_shape": summarize_password_shape(primary_secret),
        }
        try:
            response = await self._chat_completion(
                provider=provider,
                system_prompt=(
                    "You extract vault item metadata without seeing plaintext secrets. "
                    "Return JSON with item_type, template_type, name, notes, tags, fields. "
                    "Each field must include key, label, value, value_type, semantic, hidden, section, order."
                ),
                user_prompt=(
                    "Use only the supplied redacted context. Never infer the secret itself.\n"
                    f"{json.dumps(payload, ensure_ascii=True)}"
                ),
            )
            parsed = json.loads(response)
            merged_fields = self._merge_fields(
                heuristic.fields,
                [VaultFieldPayload(**item) for item in parsed.get("fields", [])],
            )
            return EnrichedItem(
                item_type=parsed.get("item_type") or heuristic.item_type,
                template_type=parsed.get("template_type") or heuristic.template_type,
                name=parsed.get("name") or heuristic.name,
                notes=parsed.get("notes") or heuristic.notes,
                tags=[str(tag) for tag in parsed.get("tags", heuristic.tags)],
                fields=merged_fields,
            )
        except Exception:
            return heuristic

    def parse_pasted_secret(self, pasted_text: str | None) -> ParsedPastedSecret:
        raw = (pasted_text or "").strip()
        lowered = raw.lower()
        kv_pairs = self._extract_key_values(raw)

        template_type = self._detect_template_type(lowered, kv_pairs)
        item_type = "login" if template_type == "account" else "secret"

        fields: list[VaultFieldPayload] = []
        tags = [template_type] if template_type else ["custom"]
        secret = self._extract_secret(kv_pairs, raw)

        if template_type == "redis":
            fields.extend(self._parse_redis_fields(raw, kv_pairs))
        elif template_type == "database":
            fields.extend(self._parse_database_fields(raw, kv_pairs))
        elif template_type == "s3":
            fields.extend(self._parse_s3_fields(kv_pairs))
        elif template_type == "kafka":
            fields.extend(self._parse_kafka_fields(kv_pairs))
        elif template_type == "aksk":
            fields.extend(self._parse_aksk_fields(kv_pairs))
        elif template_type == "account":
            fields.extend(self._parse_account_fields(kv_pairs))
        else:
            fields.extend(self._parse_generic_fields(kv_pairs))

        username = self._lookup_value(kv_pairs, self.USERNAME_KEYS)
        if username and not any(field.key == "username" for field in fields):
            fields.insert(0, self._field("username", "Username", username, semantic="username", section="Auth", order=0))

        redacted_excerpt = self._redact_excerpt(raw, secret)
        if redacted_excerpt and not any(field.key == "source_excerpt" for field in fields):
            fields.append(
                self._field(
                    "source_excerpt",
                    "Source Excerpt",
                    redacted_excerpt[:240],
                    semantic="source_excerpt",
                    section="Metadata",
                    order=999,
                )
            )

        # A "名称：xxx" line is the user's own label — it should become the title
        # just like a manually entered name would.
        user_label = (kv_pairs.get("item_label") or "").strip()
        name = user_label[:32] if 2 <= len(user_label) <= 32 else self._derive_name(template_type, kv_pairs, fields)
        notes = self._derive_notes(template_type, kv_pairs, redacted_excerpt)
        return ParsedPastedSecret(
            item_type=item_type,
            template_type=template_type,
            primary_secret=secret,
            name=name,
            notes=notes,
            tags=list(dict.fromkeys(tags)),
            fields=self._merge_fields(fields, []),
            redacted_excerpt=redacted_excerpt,
        )

    def sanitize_fields(self, fields: list[VaultFieldPayload], primary_secret: str | None) -> list[VaultFieldPayload]:
        if not primary_secret:
            return fields

        sanitized: list[VaultFieldPayload] = []
        for field in fields:
            value = field.value.replace(primary_secret, "[REDACTED]") if field.value else field.value
            sanitized.append(
                VaultFieldPayload(
                    key=field.key,
                    label=field.label,
                    value=value,
                    value_type=field.value_type,
                    semantic=field.semantic,
                    hidden=field.hidden,
                    section=field.section,
                    order=field.order,
                )
            )
        return sanitized

    async def rerank_candidates(
        self,
        provider: ProviderConfig | None,
        query: str,
        candidates: list[VaultRecord],
    ) -> list[tuple[str, str]]:
        if not candidates:
            return []

        if provider is None:
            return self._heuristic_rerank(query, candidates)

        rendered = [
            {
                "id": candidate.id,
                "item_type": candidate.record_type,
                "name": candidate.title,
                "notes": candidate.description,
                "tags": candidate.tags,
                "fields_json": candidate.fields_json,
            }
            for candidate in candidates
        ]
        try:
            response = await self._chat_completion(
                provider=provider,
                system_prompt=(
                    "You rank vault search candidates using only descriptions and metadata. "
                    "Return JSON object with key results, where results is an ordered array of "
                    "objects shaped like {id, reason}."
                ),
                user_prompt=f"Query: {query}\nCandidates: {json.dumps(rendered, ensure_ascii=True)}",
            )
            parsed = json.loads(response)
            items = parsed.get("results", [])
            return [(item["id"], item.get("reason", "AI semantic match")) for item in items]
        except Exception:
            return [(candidate.id, "fallback ordering") for candidate in candidates]

    def _query_tokens(self, query: str) -> list[str]:
        """Split a search query into matchable tokens: latin/digit words plus
        Chinese character bigrams (with stop-character grams dropped)."""
        lowered = (query or "").lower()
        tokens: list[str] = []
        seen: set[str] = set()

        def add(token: str) -> None:
            if token and token not in seen:
                seen.add(token)
                tokens.append(token)

        for word in re.findall(r"[a-z0-9][a-z0-9_\-.]+", lowered):
            add(word)
        for segment in re.findall(r"[\u4e00-\u9fff]+", lowered):
            if len(segment) == 1:
                add(segment)
                continue
            for i in range(len(segment) - 1):
                gram = segment[i : i + 2]
                if not re.search(r"[的了是吧呢吗啊嘛哦我你他她它么之乎与跟就也]", gram):
                    add(gram)
        return tokens

    def _heuristic_rerank(self, query: str, candidates: list[VaultRecord]) -> list[tuple[str, str]]:
        """Token-overlap scoring over title/description/metadata. Metadata only —
        the plaintext secret never participates in ranking."""
        tokens = self._query_tokens(query)
        if not tokens:
            return [(candidate.id, "fallback ordering") for candidate in candidates]

        docs: list[tuple[str, str, str]] = []
        for candidate in candidates:
            title = (candidate.title or "").lower()
            description = (candidate.description or "").lower()
            meta = " ".join(
                part
                for part in [candidate.tags, candidate.username, candidate.record_type, candidate.fields_json]
                if part
            ).lower()
            docs.append((title, description, meta))

        doc_count = len(docs)
        weights: dict[str, float] = {}
        for token in tokens:
            df = sum(1 for title, description, meta in docs if token in title or token in description or token in meta)
            if doc_count and df / doc_count > 0.5:
                # Ubiquitous tokens ("密码", "账号") are noise for ranking.
                weights[token] = 0.2
            else:
                weights[token] = 1.0 + 3.0 * (doc_count - df) / max(doc_count, 1)

        scored: list[tuple[float, int, str, str]] = []
        for index, (candidate, (title, description, meta)) in enumerate(zip(candidates, docs)):
            score = 0.0
            for token in tokens:
                weight = weights[token]
                if token in title:
                    score += 3.0 * weight
                if token in description:
                    score += 2.0 * weight
                if token in meta:
                    score += 1.0 * weight
            scored.append((-score, index, candidate.id, "keyword semantic match"))
        scored.sort(key=lambda item: (item[0], item[1]))
        return [(record_id, reason) for _, _, record_id, reason in scored]

    async def _chat_completion(self, provider: ProviderConfig, system_prompt: str, user_prompt: str) -> str:
        base_url = provider.base_url.rstrip("/")
        url = f"{base_url}/chat/completions"
        payload = {
            "model": provider.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            "temperature": 0.1,
            "response_format": {"type": "json_object"},
        }
        async with httpx.AsyncClient(timeout=settings.ai_timeout_seconds) as client:
            response = await client.post(
                url,
                headers={"Authorization": f"Bearer {provider.api_key}"},
                json=payload,
            )
            response.raise_for_status()
            body = response.json()
            return body["choices"][0]["message"]["content"]

    def _heuristic_enrichment(
        self,
        item_type: str,
        template_type: str | None,
        name: str | None,
        primary_secret: str,
        pasted_text: str | None,
        notes: str | None,
        tags: list[str],
        fields: list[VaultFieldPayload],
    ) -> EnrichedItem:
        merged_tags = ["vault-item", item_type.lower()]
        if template_type:
            merged_tags.append(template_type.lower())
        merged_tags.extend(tag.lower() for tag in tags)

        title_value = name or self._field_value(fields, "host") or self._field_value(fields, "service") or f"{item_type.title()} item"
        summary_bits = [notes, self._field_value(fields, "username"), self._field_value(fields, "host"), self._field_value(fields, "endpoint"), self._field_value(fields, "database")]
        resolved_notes = notes or " | ".join(bit for bit in summary_bits if bit) or "Imported vault item"

        enriched_fields = list(fields)
        excerpt = (pasted_text or "").strip()
        if excerpt and not any(field.key == "source_excerpt" for field in enriched_fields):
            enriched_fields.append(
                VaultFieldPayload(
                    key="source_excerpt",
                    label="Source Excerpt",
                    value=excerpt[:240],
                    value_type="text",
                    semantic="source_excerpt",
                    hidden=False,
                    section="Metadata",
                    order=999,
                )
            )
        return EnrichedItem(
            item_type=item_type.lower(),
            template_type=template_type,
            name=title_value,
            notes=resolved_notes,
            tags=list(dict.fromkeys(merged_tags)),
            fields=self._merge_fields(enriched_fields, []),
        )

    def _merge_fields(
        self,
        base_fields: list[VaultFieldPayload],
        override_fields: list[VaultFieldPayload],
    ) -> list[VaultFieldPayload]:
        merged: dict[str, VaultFieldPayload] = {field.key: field for field in base_fields}
        for field in override_fields:
            merged[field.key] = field
        return sorted(merged.values(), key=lambda field: (field.section or "", field.order, field.label))

    def _field_value(self, fields: list[VaultFieldPayload], key: str) -> str | None:
        for field in fields:
            if field.key == key or field.semantic == key:
                return field.value or None
        return None

    def _canonical_key(self, key: str) -> str:
        normalized = key.strip().lower().replace("-", "_").replace(".", "_")
        if normalized in self.CHINESE_KEY_ALIASES:
            return self.CHINESE_KEY_ALIASES[normalized]
        for alias, canonical in self.CHINESE_KEY_ALIASES.items():
            if len(alias) >= 2 and normalized.endswith(alias):
                return canonical
        return normalized

    def _extract_key_values(self, raw: str) -> dict[str, str]:
        pairs: dict[str, str] = {}
        for line in re.split(r"[\n;；]+", raw):
            line = line.strip()
            if not line:
                continue
            matches = list(self.KV_PAIR_RE.finditer(line)) or [
                # chat-record lines like "账号是 pm_growth 密码 Growth2026" rely on
                # the natural-language form once the kv form misses.
                match
                for match in self.NL_KV_RE.finditer(line)
            ]
            for match in matches:
                key = self._canonical_key(match.group(1))
                value = match.group(2).strip().strip("'\"")
                # First occurrence wins so multi-account pastes keep their first
                # credential block intact instead of overwriting with the last.
                if value and key not in pairs:
                    pairs[key] = value
        return pairs

    def _detect_template_type(self, lowered: str, kv_pairs: dict[str, str]) -> str | None:
        keys = set(kv_pairs)
        if "amqp://" in lowered or "rabbitmq" in lowered or "vhost" in keys:
            return "custom"
        if "redis://" in lowered or "redis" in lowered or {"db", "host", "port"} <= keys and "redis" in lowered:
            return "redis"
        if "kafka" in lowered or "brokers" in keys or "sasl_password" in keys or "topic" in keys:
            return "kafka"
        if (
            "s3" in lowered
            or "bucket" in keys
            or {"aws_access_key_id", "aws_secret_access_key"} <= keys
            or "s3_endpoint" in keys
            or "对象存储" in lowered
            or "存储桶" in lowered
            or "素材桶" in lowered
        ):
            return "s3"
        if (
            any(token in lowered for token in ["postgres", "postgresql://", "mysql", "mariadb", "clickhouse", "oracle", "sqlserver", "jdbc:", "mongodb://"])
            or "database" in keys
            or "数据库" in lowered
            or ("engine" in keys and kv_pairs.get("engine") not in {"rabbitmq"})
        ):
            return "database"
        if (
            {"access_key", "secret_key"} <= keys
            or {"ak", "sk"} <= keys
            or {"access_key_id", "secret_key"} <= keys
            or {"access_key", "access_key_id"} & keys and "secret_key" in keys
            or "accesskey" in lowered.replace(" ", "").replace("_", "")
            or ("access key" in lowered and "secret" in lowered)
        ):
            return "aksk"
        if (
            any(token in lowered for token in ["github", "gitlab", "slack", "account", "login"])
            or {"service", "account", "email"} & keys
            or any(token in lowered for token in ["网站", "网址", "登录", "登陆", "后台", "门户", "账号", "帐号", "账户", "邮箱", "用户名", "平台", "地址"])
        ):
            return "account"
        return None

    def _extract_secret(self, kv_pairs: dict[str, str], raw: str) -> str | None:
        for key in self.SECRET_KEY_ORDER:
            value = kv_pairs.get(key)
            if value:
                return value

        # URI-embedded secrets: allow the empty-username form ("redis://:pwd@host")
        # and percent-decode, since URIs carry the URL-encoded password.
        redis_url_match = re.search(r"redis://(?:[^:@/\s]*:)?(?P<secret>[^@/\s]+)@[^/\s]+(?:/(?P<db>\d+))?", raw, re.IGNORECASE)
        if redis_url_match:
            return unquote(redis_url_match.group("secret"))

        db_url_match = re.search(r"(?:postgresql|postgres|mysql|mariadb|clickhouse|mongodb)://(?:[^:@/\s]*:)?(?P<secret>[^@/\s]+)@[^/\s]+", raw, re.IGNORECASE)
        if db_url_match:
            return unquote(db_url_match.group("secret"))

        amqp_match = re.search(r"amqp://(?:[^:@/\s]*:)?(?P<secret>[^@/\s]+)@[^/\s]+", raw, re.IGNORECASE)
        if amqp_match:
            return unquote(amqp_match.group("secret"))

        # "password=x" tokens. Stop at "&" so query strings ("...&ssl=true") are not
        # swallowed, and percent-decode only inside URL context so plain .env
        # passwords that legitimately contain "%40" stay intact.
        scheme_secret_match = re.search(r"(?:password|passwd|pwd|secret|token)\s*[:：=＝]\s*([^\s,；;&，]+)", raw, re.IGNORECASE)
        if scheme_secret_match:
            value = scheme_secret_match.group(1).strip().strip("'\"")
            if "%" in value and "://" in raw:
                value = unquote(value)
            return value

        natural_match = self._natural_language_secret(raw)
        if natural_match:
            return natural_match

        next_line_match = self._next_line_secret(raw)
        if next_line_match:
            return next_line_match

        return self._bare_text_secret(raw)

    def _plausible_secret_value(self, value: str | None) -> str | None:
        if not value:
            return None
        candidate = value.strip().strip("'\"")
        if not candidate:
            return None
        if candidate in self.NL_VALUE_STOPWORDS:
            return None
        if not re.search(r"[A-Za-z0-9]", candidate):
            # Pure-CJK passwords are common for novice users ("菜篮子记个账"),
            # but pronoun-led phrases are instructions, not secrets.
            if len(candidate) < 4 or re.match(r"[你我他她它您]", candidate):
                return None
        return candidate

    def _natural_language_secret(self, raw: str) -> str | None:
        for pattern in self.NL_SECRET_PATTERNS:
            match = pattern.search(raw)
            if match:
                plausible = self._plausible_secret_value(match.group(1))
                if plausible:
                    return plausible
        return None

    def _next_line_secret(self, raw: str) -> str | None:
        """Chat handoff style: the keyword ends a line, the secret is the next line."""
        keyword_re = re.compile(r"(?:密码|口令|密碼|密钥|秘钥|secret[\s\-]?key|access[\s\-]?key|token|授权码|提取码|激活码|兑换码|卡密|购买码)[^：:=＝\n]*$", re.IGNORECASE)
        lines = raw.splitlines()
        for index, line in enumerate(lines[:-1]):
            if keyword_re.search(line.rstrip()):
                for candidate in lines[index + 1 :]:
                    candidate = candidate.strip()
                    if not candidate:
                        continue
                    if len(candidate.split()) == 1 and len(candidate) <= 72:
                        return candidate.strip("'\"")
                    break
        return None

    def _bare_text_secret(self, raw: str) -> str | None:
        """Novice flow: the paste is just the password itself ("hg_6688@2026")."""
        text = raw.strip()
        if not text or len(text) > 72:
            return None
        if self.URI_SCHEME_RE.match(text):
            return None
        if not re.search(r"[A-Za-z0-9]", text):
            return None
        tokens = text.split()
        if len(tokens) == 1:
            return text
        # "商城名 hg_6688@2026": label + credential, where the credential is the
        # longer alphanumeric-mixed token.
        if len(tokens) == 2:
            first, second = tokens
            candidate = second if len(second) >= len(first) else first
            if len(candidate) >= 6 and re.search(r"[A-Za-z]", candidate) and re.search(r"\d", candidate):
                return candidate
        return None

    def _parse_redis_fields(self, raw: str, kv_pairs: dict[str, str]) -> list[VaultFieldPayload]:
        fields: list[VaultFieldPayload] = []
        redis_url = re.search(r"redis://(?:(?P<username>[^:@/\s]+):)?(?P<secret>[^@/\s]+)@(?P<host>[^:/\s]+):(?P<port>\d+)(?:/(?P<db>\d+))?", raw, re.IGNORECASE)
        if redis_url:
            if redis_url.group("username"):
                fields.append(self._field("username", "Username", redis_url.group("username"), semantic="username", section="Auth", order=0))
            fields.append(self._field("host", "Host", redis_url.group("host"), semantic="host", section="Connection", order=1))
            fields.append(self._field("port", "Port", redis_url.group("port"), value_type="number", semantic="port", section="Connection", order=2))
            if redis_url.group("db"):
                fields.append(self._field("db", "Database", redis_url.group("db"), value_type="number", semantic="database", section="Connection", order=3))
            fields.append(self._field("url", "URL", redis_url.group(0), value_type="url", semantic="uri", section="Connection", order=4))
            return fields

        if host := self._lookup_value(kv_pairs, {"host", "hostname"}):
            fields.append(self._field("host", "Host", host, semantic="host", section="Connection", order=1))
        if port := self._lookup_value(kv_pairs, {"port"}):
            fields.append(self._field("port", "Port", port, value_type="number", semantic="port", section="Connection", order=2))
        if db := self._lookup_value(kv_pairs, {"db", "database"}):
            fields.append(self._field("db", "Database", db, value_type="number", semantic="database", section="Connection", order=3))
        if url := self._lookup_value(kv_pairs, {"url", "redis_url"}):
            fields.append(self._field("url", "URL", url, value_type="url", semantic="uri", section="Connection", order=4))
        return fields

    def _parse_database_fields(self, raw: str, kv_pairs: dict[str, str]) -> list[VaultFieldPayload]:
        fields: list[VaultFieldPayload] = []
        engine = self._lookup_value(kv_pairs, {"engine", "driver"}) or self._detect_database_engine(raw.lower())
        if engine:
            fields.append(self._field("engine", "Engine", engine, semantic="engine", section="Connection", order=1))
        if host := self._lookup_value(kv_pairs, {"host", "hostname"}):
            fields.append(self._field("host", "Host", host, semantic="host", section="Connection", order=2))
        if port := self._lookup_value(kv_pairs, {"port"}):
            fields.append(self._field("port", "Port", port, value_type="number", semantic="port", section="Connection", order=3))
        if database := self._lookup_value(kv_pairs, {"database", "dbname", "db"}):
            fields.append(self._field("database", "Database", database, semantic="database", section="Connection", order=4))

        url_value = self._lookup_value(kv_pairs, self.URL_KEYS)
        if not url_value:
            uri_match = re.search(r"((?:postgresql|postgres|mysql|mariadb|clickhouse|mongodb)://[^\s]+)", raw, re.IGNORECASE)
            if uri_match:
                url_value = uri_match.group(1)
        if url_value:
            parsed = urlparse(url_value)
            if parsed.hostname and not any(field.key == "host" for field in fields):
                fields.append(self._field("host", "Host", parsed.hostname, semantic="host", section="Connection", order=2))
            try:
                parsed_port = parsed.port
            except ValueError:
                parsed_port = None
            if parsed_port and not any(field.key == "port" for field in fields):
                fields.append(self._field("port", "Port", str(parsed_port), value_type="number", semantic="port", section="Connection", order=3))
            if parsed.path and parsed.path != "/" and not any(field.key == "database" for field in fields):
                fields.append(self._field("database", "Database", parsed.path.removeprefix("/"), semantic="database", section="Connection", order=4))
            if parsed.username and not any(field.key == "username" for field in fields):
                fields.append(self._field("username", "Username", parsed.username, semantic="username", section="Auth", order=0))
        return fields

    def _parse_s3_fields(self, kv_pairs: dict[str, str]) -> list[VaultFieldPayload]:
        fields: list[VaultFieldPayload] = []
        if endpoint := self._lookup_value(kv_pairs, {"endpoint", "s3_endpoint", "url", "host"}):
            fields.append(self._field("endpoint", "Endpoint", endpoint, value_type="url", semantic="endpoint", section="Connection", order=1))
        if bucket := self._lookup_value(kv_pairs, {"bucket"}):
            fields.append(self._field("bucket", "Bucket", bucket, semantic="bucket", section="Connection", order=2))
        if access_key := self._lookup_value(kv_pairs, {"access_key", "ak", "aws_access_key_id"}):
            fields.append(self._field("access_key", "Access Key", access_key, semantic="access_key", section="Auth", order=3))
        if region := self._lookup_value(kv_pairs, {"region", "aws_default_region"}):
            fields.append(self._field("region", "Region", region, semantic="region", section="Connection", order=4))
        return fields

    def _parse_kafka_fields(self, kv_pairs: dict[str, str]) -> list[VaultFieldPayload]:
        fields: list[VaultFieldPayload] = []
        if brokers := self._lookup_value(kv_pairs, {"brokers", "bootstrap_servers", "bootstrap"}):
            fields.append(self._field("brokers", "Brokers", brokers, semantic="brokers", section="Connection", order=1))
        if mechanism := self._lookup_value(kv_pairs, {"mechanism", "sasl_mechanism"}):
            fields.append(self._field("mechanism", "Mechanism", mechanism, semantic="mechanism", section="Auth", order=2))
        if topic := self._lookup_value(kv_pairs, {"topic"}):
            fields.append(self._field("topic", "Topic", topic, semantic="topic", section="Connection", order=3))
        if username := self._lookup_value(kv_pairs, {"sasl_username", "username", "user"}):
            fields.append(self._field("username", "Username", username, semantic="username", section="Auth", order=0))
        return fields

    def _parse_aksk_fields(self, kv_pairs: dict[str, str]) -> list[VaultFieldPayload]:
        fields: list[VaultFieldPayload] = []
        if provider := self._lookup_value(kv_pairs, {"provider", "cloud"}):
            fields.append(self._field("provider", "Provider", provider, semantic="provider", section="Details", order=1))
        if access_key := self._lookup_value(kv_pairs, {"access_key", "ak"}):
            fields.append(self._field("access_key", "Access Key", access_key, semantic="access_key", section="Auth", order=2))
        if scope := self._lookup_value(kv_pairs, {"scope", "project", "tenant"}):
            fields.append(self._field("scope", "Scope", scope, semantic="scope", section="Details", order=3))
        if region := self._lookup_value(kv_pairs, {"region"}):
            fields.append(self._field("region", "Region", region, semantic="region", section="Details", order=4))
        return fields

    def _parse_account_fields(self, kv_pairs: dict[str, str]) -> list[VaultFieldPayload]:
        fields: list[VaultFieldPayload] = []
        if service := self._lookup_value(kv_pairs, {"service", "site", "provider"}):
            fields.append(self._field("service", "Service", service, semantic="service", section="Login", order=1))
        if account := self._lookup_value(kv_pairs, {"account", "email", "user", "username"}):
            fields.append(self._field("account", "Account", account, semantic="account", section="Login", order=2))
        if url := self._lookup_value(kv_pairs, {"url", "site_url", "uri"}):
            fields.append(self._field("url", "URL", url, value_type="url", semantic="uri", section="Login", order=3))
        return fields

    def _parse_generic_fields(self, kv_pairs: dict[str, str]) -> list[VaultFieldPayload]:
        fields: list[VaultFieldPayload] = []
        order = 1
        for key, value in kv_pairs.items():
            if key in self.SECRET_KEYS:
                continue
            if key in self.URL_KEYS:
                value_type = "url"
            elif key in {"port"}:
                value_type = "number"
            else:
                value_type = "text"
            fields.append(self._field(key, key.replace("_", " ").title(), value, value_type=value_type, semantic=key, section="Details", order=order))
            order += 1
        return fields

    def _derive_name(self, template_type: str | None, kv_pairs: dict[str, str], fields: list[VaultFieldPayload]) -> str | None:
        target = self._lookup_value(kv_pairs, {"service", "bucket", "host", "database", "account", "provider"})
        if template_type == "database" and target:
            engine = self._lookup_value(kv_pairs, {"engine", "driver"}) or self._detect_database_engine(" ".join(kv_pairs.values()).lower())
            if engine:
                return f"{engine.upper()} {target}"
        if template_type and target:
            return f"{template_type.upper()} {target}"
        if template_type:
            return template_type.upper()
        if target:
            return target
        host = next((field.value for field in fields if field.key == "host"), None)
        return host

    def _derive_notes(self, template_type: str | None, kv_pairs: dict[str, str], redacted_excerpt: str | None) -> str | None:
        env = self._lookup_value(kv_pairs, {"env", "environment", "namespace"})
        target = self._lookup_value(kv_pairs, {"service", "bucket", "database", "topic", "host"})
        parts = [part for part in [env, target] if part]
        if template_type and parts:
            return f"{template_type.upper()} credential for {' / '.join(parts)}"
        if redacted_excerpt:
            return redacted_excerpt[:140]
        return None

    def _detect_database_engine(self, lowered: str) -> str | None:
        for engine in ["postgres", "postgresql", "mysql", "mariadb", "clickhouse", "oracle", "sqlserver", "mongodb"]:
            if engine in lowered:
                return "postgres" if engine == "postgresql" else engine
        return None

    def _lookup_value(self, kv_pairs: dict[str, str], keys: set[str]) -> str | None:
        order = self.USERNAME_KEY_ORDER if keys is self.USERNAME_KEYS else sorted(keys)
        for key in order:
            value = kv_pairs.get(key)
            if value:
                return value
        return None

    def _redact_excerpt(self, raw: str, secret: str | None) -> str | None:
        excerpt = raw.strip()
        if not excerpt:
            return None
        if secret:
            excerpt = excerpt.replace(secret, "[REDACTED]")
        excerpt = re.sub(r"(?i)(password|passwd|pwd|secret|token|sasl_password|secret_key)\s*[:=]\s*([^\s,;]+)", r"\1=[REDACTED]", excerpt)
        return excerpt

    def _field(
        self,
        key: str,
        label: str,
        value: str,
        *,
        value_type: str = "text",
        semantic: str | None = None,
        section: str | None = None,
        order: int = 0,
    ) -> VaultFieldPayload:
        return VaultFieldPayload(
            key=key,
            label=label,
            value=value,
            value_type=value_type,
            semantic=semantic,
            hidden=False,
            section=section,
            order=order,
        )


ai_service = AIService()
