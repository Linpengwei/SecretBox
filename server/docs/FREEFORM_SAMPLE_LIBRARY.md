# Freeform Sample Library

This file is a hand-test library for the menu bar MVP.

For the current macOS classifier regression set, see:

- [DIVERSE_FIFTY_SAMPLE_SET.md](./DIVERSE_FIFTY_SAMPLE_SET.md)
- [diverse_fifty_samples.json](./diverse_fifty_samples.json)

- `tested`: covered by automated API regression tests.
- `manual`: not yet in automated tests, but added for manual parsing checks.
- All credentials below are synthetic samples derived from public GitHub configuration patterns, not real secrets.

## Redis

1. `tested` `redis://default:RedisProd#2026@redis-prod.internal:6379/0 env=prod service=order-cache region=shanghai`
2. `tested` `host=redis-staging.internal port=6380 db=2 username=default password=RedisStage!2026 env=staging service=session-cache redis`
3. `tested` `REDISCLI_AUTH=RedisCliOnly#2026 redis-cli -h redis-ops.internal -p 6379 -n 5 env=ops redis`
4. `manual` `REDIS_URL=redis://cache-user:CacheOnly!2026@cache.internal:6379/4 namespace=payment env=prod`
5. `manual` `redis host=redis-dev.internal port=6379 db=9 password=RedisDev#2026 service=feature-flag`
6. `manual` `redis://:RedisNoUser!2026@redis-no-user.internal:6379/1 team=ops`
7. `manual` `cache.redis.url=redis://default:SpringRedis!2026@redis-spring.internal:6379/0 env=qa`
8. `manual` `spring.data.redis.host=redis-app.internal spring.data.redis.port=6379 spring.data.redis.password=SpringDataRedis#2026`
9. `manual` `REDIS_PASSWORD=OnlyPassword#2026 host=redis-password-only.internal port=6379`
10. `manual` `redis sentinel=mymaster host=redis-sentinel.internal port=26379 password=SentinelAuth!2026`

## Database

11. `tested` `DATABASE_URL=postgresql://billing_admin:PgBilling%232026@billing-db.internal:5432/billing env=prod service=reconciliation`
12. `tested` `host=db.github.internal port=5432 dbname=accounts user=liuhanze password=P@ssw0rd! engine=postgres env=prod`
13. `tested` `mysql://app_user:MySQLApp!2026@mysql-prod.internal:3306/orders?charset=utf8mb4 env=prod service=order-api`
14. `tested` `host=clickhouse-01.internal port=8123 user=analytics password=CHAnalytics#2026 database=events engine=clickhouse env=prod`
15. `tested` `mongodb://report_user:MongoReport%402026@mongo-01.internal:27017,repl-02.internal:27017/reports?replicaSet=rs0 env=prod team=data`
16. `manual` `SPRING_DATASOURCE_URL=jdbc:postgresql://order-db.internal:5432/orders SPRING_DATASOURCE_USERNAME=app SPRING_DATASOURCE_PASSWORD=SpringJdbc#2026`
17. `manual` `JDBC_URL=jdbc:mysql://mysql-stage.internal:3306/app?useSSL=false username=stage_user password=JdbcMySQL!2026`
18. `manual` `sqlserver://sa:SqlServer!2026@sql-prod.internal:1433;databaseName=erp env=prod`
19. `manual` `oracle user=finance_app password=OracleFin#2026 host=oracle.internal port=1521 service=FINPDB1`
20. `manual` `MONGO_URL=mongodb://svc_reader:MongoSvc#2026@mongo.internal:27017/appdb authSource=admin`

## S3 And Object Storage

21. `tested` `AWS_ACCESS_KEY_ID=AKIAOPS123 AWS_SECRET_ACCESS_KEY=S3SecretOps! AWS_DEFAULT_REGION=ap-east-1 S3_ENDPOINT=https://s3.internal.example.com bucket=artifacts-release`
22. `tested` `access_key=deploy-artifacts-ak secret_key=DeploySecret#2026 endpoint=https://minio.internal bucket=build-cache region=cn-east-1`
23. `tested` `MINIO_ROOT_USER=minio-root MINIO_ROOT_PASSWORD=MinioRoot!2026 endpoint=https://minio-prod.internal bucket=infra-backups`
24. `tested` `provider=aliyun ak=LTAI5TEXAMPLE sk=AliyunSK#2026 scope=oss-prod region=cn-shanghai`
25. `tested` `provider=tencent access_key=TCloudAK001 secret_key=TCloudSecret!2026 scope=cos-backup region=ap-shanghai`
26. `manual` `AWS_BUCKET_NAME=frontend-assets AWS_ACCESS_KEY_ID=AKIABUILD01 AWS_SECRET_ACCESS_KEY=BuildBucket!2026 AWS_REGION=us-west-2`
27. `manual` `AWS_S3_BUCKET=release-bucket AWS_S3_ENDPOINT=https://nyc3.digitaloceanspaces.com AWS_ACCESS_KEY_ID=DOAccess01 AWS_SECRET_ACCESS_KEY=DOSpaces!2026`
28. `manual` `MINIO_SERVER_URL=https://minio.example.com MINIO_ROOT_USER=backup-admin MINIO_ROOT_PASSWORD=BackupAdmin!2026`
29. `manual` `S3_BUCKET=helm-charts S3_ENDPOINT=https://s3-gateway.internal ACCESS_KEY=charts-ak SECRET_KEY=ChartsSecret#2026`
30. `manual` `COS_SECRET_ID=COSAK001 COS_SECRET_KEY=COSSecret!2026 bucket=archive-data region=ap-singapore provider=tencent`

## Kafka And MQ

31. `tested` `brokers=kafka-1.internal:9092,kafka-2.internal:9092 sasl.username="audit_pipeline" sasl.password="KafkaAudit!2026" mechanism=SCRAM-SHA-512 topic=audit.events env=prod`
32. `tested` `bootstrap_servers=broker-a.internal:9092,broker-b.internal:9092 username=etl_consumer sasl_password=ETLConsumer#2026 topic=etl.jobs kafka cluster=prod`
33. `tested` `amqp://rabbit_user:RabbitMQ!2026@mq-prod.internal:5672/prod-vhost service=payments queue=settlement rabbitmq`
34. `tested` `host=mq-stage.internal port=5672 username=ops password=RabbitStage#2026 vhost=stage engine=rabbitmq`
35. `manual` `bootstrap.servers=kafka-a.internal:9092,kafka-b.internal:9092 sasl.jaas.config=username="metrics" password="MetricsKafka!2026" sasl.mechanism=PLAIN`
36. `manual` `KAFKA_BROKERS=broker-1.internal:9092,broker-2.internal:9092 KAFKA_USERNAME=producer KAFKA_PASSWORD=ProducerKafka!2026 TOPIC=orders.created`
37. `manual` `rabbitmq hosts: host1 port:5672 user:guest password:guest vhost:/ queue:default`
38. `manual` `queue_host=mq-dr.internal queue_port=5672 queue_user=alert queue_password=AlertQueue#2026 vhost=alerts`
39. `manual` `NATS_URL=nats://nats_user:NatsOps#2026@nats.internal:4222 env=prod`
40. `manual` `PULSAR_SERVICE_URL=pulsar://pulsar.internal:6650 authToken=PulseAuth#2026 tenant=ops namespace=prod`

## Account And Platform Login

41. `tested` `service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod`
42. `tested` `account=gitlab-ci-bot email=ci-bot@example.com passwd=GitLabCI!2026 service=GitLab url=https://gitlab.example.com`
43. `tested` `service=Harbor username=robot$deploy password=HarborRobot#2026 url=https://harbor.internal project=release-images`
44. `manual` `service=Jenkins username=release-admin password=JenkinsRelease!2026 url=https://jenkins.internal folder=deploy`
45. `manual` `service=Grafana username=ops-admin password=GrafanaOps#2026 url=https://grafana.internal org=Main`
46. `manual` `service=Prometheus basic_auth_user=prom-reader basic_auth_password=PromRead!2026 url=https://prom.internal`
47. `manual` `service=OpenSearch username=search_admin password=OpenSearch!2026 url=https://search.internal domain=logs`
48. `manual` `service=Elasticsearch user=elastic password=ElasticOps#2026 url=https://es.internal cluster=prod`
49. `manual` `service=Vault token=VaultRoot#2026 url=https://vault.internal namespace=platform`
50. `manual` `OPENAI_BASE_URL=https://api.example.com/v1 OPENAI_API_KEY=sk-test-SecretBox-2026 model=gpt-4o-mini provider=openai-compatible`

## Notes

- The current parser is strongest on `redis`, `database`, `s3`, `kafka`, `account`, and `aksk`.
- Samples marked `manual` are good candidates for future parser expansion.
- For manual testing in the app, paste any single line into the menu bar panel and click `保存`.
