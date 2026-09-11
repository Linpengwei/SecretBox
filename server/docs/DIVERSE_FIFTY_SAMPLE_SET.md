# Diverse Fifty Sample Set

This file exports the current 50-sample heterogeneous freeform credential set used by the macOS app classifier regression tests.

- All entries are synthetic.
- They are intended for local parsing, clustering, and classification regression.
- Source of truth in code: `SecretBox/SecretBoxTests/SecretBoxAppModelTests.swift`

## Coverage

- `redis`: 5
- `database`: 10
- `s3`: 5
- `kafka`: 5
- `account`: 10
- `aksk`: 5
- `custom` routed into `messageQueueCredential`: 5
- `custom/account` routed into `serviceEndpointSecret`: 5

## Samples

| # | label | expected type | expected cluster | sample |
|---|---|---|---|---|
| 1 | `redis-uri-prod` | `redis` | `cacheCredential` | `redis://default:RedisProd#2026@redis-prod.internal:6379/0 env=prod service=order-cache` |
| 2 | `redis-kv-stage` | `redis` | `cacheCredential` | `host=redis-stage.internal port=6380 db=2 username=default password=RedisStage!2026 env=staging service=session-cache` |
| 3 | `redis-cli-auth` | `redis` | `cacheCredential` | `REDISCLI_AUTH=RedisCliOnly#2026 redis-cli -h redis-ops.internal -p 6379 -n 5 env=ops` |
| 4 | `redis-url-inline` | `redis` | `cacheCredential` | `redis_url=redis://cache-user:CacheSecret#2026@redis-cache.internal:6379/4 label=payments-cache env=prod` |
| 5 | `redis-config-note` | `redis` | `cacheCredential` | `redis host=cache-east.internal port=6379 database=9 password=CacheEast#2026 service=feed-cache region=cn-shanghai` |
| 6 | `postgres-database-url` | `database` | `relationalDBCredential` | `DATABASE_URL=postgresql://billing_admin:PgBilling%232026@billing-db.internal:5432/billing env=prod service=reconciliation` |
| 7 | `postgres-kv` | `database` | `relationalDBCredential` | `host=db.github.internal port=5432 dbname=accounts user=liuhanze password=P@ssw0rd! engine=postgres env=prod` |
| 8 | `mysql-uri` | `database` | `relationalDBCredential` | `mysql://app_user:MySQLApp!2026@mysql-prod.internal:3306/orders?charset=utf8mb4 env=prod service=order-api` |
| 9 | `clickhouse-uri` | `database` | `relationalDBCredential` | `clickhouse://analytics:CHAnalytics#2026@clickhouse-01.internal:8123/events env=prod service=warehouse` |
| 10 | `mongodb-uri` | `database` | `relationalDBCredential` | `mongodb://report_user:MongoReport%402026@mongo-01.internal:27017/reports?replicaSet=rs0 env=prod team=data` |
| 11 | `mariadb-kv` | `database` | `relationalDBCredential` | `engine=mariadb host=mariadb-01.internal port=3306 database=ops user=ops_admin password=MariaOps#2026 env=prod` |
| 12 | `postgres-service-note` | `database` | `relationalDBCredential` | `engine=postgres host=ledger-db.internal port=5432 database=ledger username=ledger_rw password=LedgerRW#2026 label=ledger-prod` |
| 13 | `mysql-reporting` | `database` | `relationalDBCredential` | `database=reporting host=mysql-report.internal port=3306 user=reporting password=Reporting#2026 engine=mysql service=bi` |
| 14 | `mongodb-kv` | `database` | `relationalDBCredential` | `engine=mongodb host=mongo-bi.internal port=27017 database=analytics username=bi_reader password=MongoBI#2026 env=stage` |
| 15 | `clickhouse-kv` | `database` | `relationalDBCredential` | `engine=clickhouse host=ch-metrics.internal port=9000 database=metrics user=metrics_ro password=Metrics#2026 env=prod` |
| 16 | `aws-s3-env` | `s3` | `objectStorageCredential` | `AWS_ACCESS_KEY_ID=AKIAOPS123 AWS_SECRET_ACCESS_KEY=S3SecretOps! AWS_DEFAULT_REGION=ap-east-1 S3_ENDPOINT=https://s3.internal.example.com bucket=artifacts-release` |
| 17 | `minio-kv` | `s3` | `objectStorageCredential` | `access_key=deploy-artifacts-ak secret_key=DeploySecret#2026 endpoint=https://minio.internal bucket=build-cache region=cn-east-1` |
| 18 | `oss-provider` | `s3` | `objectStorageCredential` | `provider=aws access_key=AKIADEPLOY01 secret_key=DeployAWS#2026 endpoint=https://s3-us.internal bucket=release-assets region=us-east-1` |
| 19 | `s3-endpoint-host` | `s3` | `objectStorageCredential` | `bucket=infra-backups s3_endpoint=https://minio-prod.internal aws_access_key_id=MINIODEPLOY aws_secret_access_key=MinioDeploy!2026 aws_default_region=cn-hangzhou` |
| 20 | `storage-note` | `s3` | `objectStorageCredential` | `endpoint=https://oss.internal.example.com bucket=media-prod access_key=oss-media-ak secret_key=OssMedia#2026 provider=aliyun region=cn-shanghai` |
| 21 | `kafka-sasl` | `kafka` | `messageQueueCredential` | `brokers=kafka-1.internal:9092,kafka-2.internal:9092 sasl.username="audit_pipeline" sasl.password="KafkaAudit!2026" mechanism=SCRAM-SHA-512 topic=audit.events env=prod` |
| 22 | `kafka-bootstrap` | `kafka` | `messageQueueCredential` | `bootstrap_servers=broker-a.internal:9092,broker-b.internal:9092 username=etl_consumer sasl_password=ETLConsumer#2026 topic=etl.jobs kafka cluster=prod` |
| 23 | `kafka-plain` | `kafka` | `messageQueueCredential` | `kafka brokers=stream-a.internal:9092,stream-b.internal:9092 username=stream_ro password=StreamRO#2026 mechanism=PLAIN topic=stream.events env=prod` |
| 24 | `kafka-stage` | `kafka` | `messageQueueCredential` | `brokers=stage-kafka.internal:9092 sasl_username=stage_consumer sasl_password=StageKafka#2026 mechanism=SCRAM-SHA-256 topic=metrics.ingest env=staging` |
| 25 | `kafka-bootstrap-short` | `kafka` | `messageQueueCredential` | `bootstrap=ops-kafka.internal:9092 user=ops_ro password=OpsKafka#2026 topic=ops.audit kafka env=ops` |
| 26 | `github-account` | `account` | `humanAccountLogin` | `service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod` |
| 27 | `gitlab-account` | `account` | `humanAccountLogin` | `account=gitlab-ci-bot email=ci-bot@example.com passwd=GitLabCI!2026 service=GitLab url=https://gitlab.example.com` |
| 28 | `harbor-robot` | `account` | `humanAccountLogin` | `service=Harbor username=robot$deploy password=HarborRobot#2026 url=https://harbor.internal project=release-images` |
| 29 | `jenkins-login` | `account` | `humanAccountLogin` | `service=Jenkins username=builder-bot password=JenkinsBot#2026 url=https://jenkins.internal env=prod` |
| 30 | `grafana-login` | `account` | `humanAccountLogin` | `service=Grafana account=ops-oncall email=ops-oncall@example.com password=GrafanaOncall#2026 url=https://grafana.internal env=prod` |
| 31 | `argocd-login` | `account` | `humanAccountLogin` | `service=ArgoCD account=deploy-bot password=ArgoDeploy#2026 url=https://argocd.internal env=prod` |
| 32 | `sonarqube-login` | `account` | `humanAccountLogin` | `service=SonarQube username=quality-bot password=SonarBot#2026 url=https://sonar.internal env=staging` |
| 33 | `jira-login` | `account` | `humanAccountLogin` | `service=Jira username=ops-admin password=JiraAdmin#2026 url=https://jira.internal env=prod` |
| 34 | `gitea-login` | `account` | `humanAccountLogin` | `service=Gitea account=mirror-bot email=mirror@example.com password=GiteaMirror#2026 url=https://gitea.internal` |
| 35 | `slack-login` | `account` | `humanAccountLogin` | `service=Slack account=ops.workspace@example.com password=SlackOps#2026 url=https://workspace.slack.com env=prod` |
| 36 | `aliyun-aksk` | `aksk` | `cloudAccessPair` | `provider=aliyun ak=LTAI5TEXAMPLE sk=AliyunSK#2026 scope=oss-prod region=cn-shanghai` |
| 37 | `tencent-aksk` | `aksk` | `cloudAccessPair` | `provider=tencent access_key=TCloudAK001 secret_key=TCloudSecret!2026 project=cos-backup region=ap-shanghai` |
| 38 | `aws-aksk` | `aksk` | `cloudAccessPair` | `provider=aws access_key=AKIAOPS987 secret_key=AwsOpsSecret#2026 scope=iam-ops region=us-west-2` |
| 39 | `gcp-aksk` | `aksk` | `cloudAccessPair` | `provider=gcp ak=GCPAK0001 sk=GCPSK#2026 scope=artifact-registry region=asia-east1` |
| 40 | `azure-aksk` | `aksk` | `cloudAccessPair` | `provider=azure access_key=AZUREOPS01 secret_key=AzureOps#2026 project=blob-backup region=eastasia` |
| 41 | `amqp-uri-payments` | `custom` | `messageQueueCredential` | `amqp://rabbit_user:RabbitMQ!2026@mq-prod.internal:5672/prod-vhost service=payments queue=settlement env=prod` |
| 42 | `rabbitmq-kv-stage` | `custom` | `messageQueueCredential` | `host=mq-stage.internal port=5672 username=ops password=RabbitStage#2026 vhost=stage engine=rabbitmq queue=jobs env=stage` |
| 43 | `rabbitmq-inline` | `custom` | `messageQueueCredential` | `rabbitmq username=alerts password=RabbitAlert#2026 host=mq-alerts.internal port=5672 vhost=alerts queue=notify env=prod` |
| 44 | `amqp-orders` | `custom` | `messageQueueCredential` | `amqp://order_user:OrderMQ#2026@mq-orders.internal:5672/orders-vhost service=orders queue=order.created env=prod` |
| 45 | `rabbitmq-billing` | `custom` | `messageQueueCredential` | `engine=rabbitmq host=mq-billing.internal port=5672 username=billing password=BillingMQ#2026 vhost=billing queue=invoice.generated env=prod` |
| 46 | `service-endpoint-token` | `custom` | `serviceEndpointSecret` | `endpoint=https://vault.internal username=ops-bot token=VaultToken#2026 provider=internal env=prod` |
| 47 | `service-endpoint-password` | `custom` | `serviceEndpointSecret` | `host=api.internal username=automation password=ApiAutomation#2026 provider=platform env=prod` |
| 48 | `service-endpoint-url` | `custom` | `serviceEndpointSecret` | `url=https://registry.internal username=robot password=RegistryRobot#2026 provider=harbor env=prod` |
| 49 | `service-endpoint-login` | `account` | `serviceEndpointSecret` | `endpoint=https://nexus.internal login=artifact-ro secret=NexusRO#2026 service=nexus env=prod` |
| 50 | `service-endpoint-api` | `account` | `serviceEndpointSecret` | `host=consul.internal user=ops password=ConsulOps#2026 service=consul env=prod` |

## Suggested local checks

1. Copy any single sample into the menu bar capture input.
2. Verify `Smart Preview` extracts useful fields and tags.
3. Save locally with server features disabled.
4. Search by `host`, `url`, `service`, `bucket`, `topic`, or `env`.
