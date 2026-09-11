import XCTest
@testable import SecretBox

@MainActor
final class SecretBoxAppModelTests: XCTestCase {
    private let localRecordsKey = "SecretBox.localRecords"
    private let serverEnabledKey = "SecretBox.serverEnabled"
    private let serverURLKey = "SecretBox.serverURL"
    private let organizationLastRunKey = "SecretBox.organization.lastRun"
    private let organizationThresholdBucketKey = "SecretBox.organization.thresholdBucket"
    private let organizationSummaryKey = "SecretBox.organization.summary"
    private let organizationIntervalDaysKey = "SecretBox.organization.intervalDays"
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    private struct GeneratedSample {
        let label: String
        let text: String
        let expectedType: String
        let expectedCluster: CredentialClusterID
    }

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "SecretBoxTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        let defaults = defaults!
        defaults.removeObject(forKey: localRecordsKey)
        defaults.removeObject(forKey: serverEnabledKey)
        defaults.removeObject(forKey: serverURLKey)
        defaults.removeObject(forKey: organizationLastRunKey)
        defaults.removeObject(forKey: organizationThresholdBucketKey)
        defaults.removeObject(forKey: organizationSummaryKey)
        defaults.removeObject(forKey: organizationIntervalDaysKey)
    }

    override func tearDown() {
        let defaults = defaults!
        defaults.removeObject(forKey: localRecordsKey)
        defaults.removeObject(forKey: serverEnabledKey)
        defaults.removeObject(forKey: serverURLKey)
        defaults.removeObject(forKey: organizationLastRunKey)
        defaults.removeObject(forKey: organizationThresholdBucketKey)
        defaults.removeObject(forKey: organizationSummaryKey)
        defaults.removeObject(forKey: organizationIntervalDaysKey)
        UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        self.defaults = nil
        self.defaultsSuiteName = nil
        super.tearDown()
    }

    private func makeDiverseGeneratedSamples() -> [GeneratedSample] {
        [
            GeneratedSample(label: "redis-uri-prod", text: "redis://default:RedisProd#2026@redis-prod.internal:6379/0 env=prod service=order-cache", expectedType: "redis", expectedCluster: .cacheCredential),
            GeneratedSample(label: "redis-kv-stage", text: "host=redis-stage.internal port=6380 db=2 username=default password=RedisStage!2026 env=staging service=session-cache", expectedType: "redis", expectedCluster: .cacheCredential),
            GeneratedSample(label: "redis-cli-auth", text: "REDISCLI_AUTH=RedisCliOnly#2026 redis-cli -h redis-ops.internal -p 6379 -n 5 env=ops", expectedType: "redis", expectedCluster: .cacheCredential),
            GeneratedSample(label: "redis-url-inline", text: "redis_url=redis://cache-user:CacheSecret#2026@redis-cache.internal:6379/4 label=payments-cache env=prod", expectedType: "redis", expectedCluster: .cacheCredential),
            GeneratedSample(label: "redis-config-note", text: "redis host=cache-east.internal port=6379 database=9 password=CacheEast#2026 service=feed-cache region=cn-shanghai", expectedType: "redis", expectedCluster: .cacheCredential),

            GeneratedSample(label: "postgres-database-url", text: "DATABASE_URL=postgresql://billing_admin:PgBilling%232026@billing-db.internal:5432/billing env=prod service=reconciliation", expectedType: "database", expectedCluster: .relationalDBCredential),
            GeneratedSample(label: "postgres-kv", text: "host=db.github.internal port=5432 dbname=accounts user=liuhanze password=P@ssw0rd! engine=postgres env=prod", expectedType: "database", expectedCluster: .relationalDBCredential),
            GeneratedSample(label: "mysql-uri", text: "mysql://app_user:MySQLApp!2026@mysql-prod.internal:3306/orders?charset=utf8mb4 env=prod service=order-api", expectedType: "database", expectedCluster: .relationalDBCredential),
            GeneratedSample(label: "clickhouse-uri", text: "clickhouse://analytics:CHAnalytics#2026@clickhouse-01.internal:8123/events env=prod service=warehouse", expectedType: "database", expectedCluster: .relationalDBCredential),
            GeneratedSample(label: "mongodb-uri", text: "mongodb://report_user:MongoReport%402026@mongo-01.internal:27017/reports?replicaSet=rs0 env=prod team=data", expectedType: "database", expectedCluster: .relationalDBCredential),
            GeneratedSample(label: "mariadb-kv", text: "engine=mariadb host=mariadb-01.internal port=3306 database=ops user=ops_admin password=MariaOps#2026 env=prod", expectedType: "database", expectedCluster: .relationalDBCredential),
            GeneratedSample(label: "postgres-service-note", text: "engine=postgres host=ledger-db.internal port=5432 database=ledger username=ledger_rw password=LedgerRW#2026 label=ledger-prod", expectedType: "database", expectedCluster: .relationalDBCredential),
            GeneratedSample(label: "mysql-reporting", text: "database=reporting host=mysql-report.internal port=3306 user=reporting password=Reporting#2026 engine=mysql service=bi", expectedType: "database", expectedCluster: .relationalDBCredential),
            GeneratedSample(label: "mongodb-kv", text: "engine=mongodb host=mongo-bi.internal port=27017 database=analytics username=bi_reader password=MongoBI#2026 env=stage", expectedType: "database", expectedCluster: .relationalDBCredential),
            GeneratedSample(label: "clickhouse-kv", text: "engine=clickhouse host=ch-metrics.internal port=9000 database=metrics user=metrics_ro password=Metrics#2026 env=prod", expectedType: "database", expectedCluster: .relationalDBCredential),

            GeneratedSample(label: "aws-s3-env", text: "AWS_ACCESS_KEY_ID=AKIAOPS123 AWS_SECRET_ACCESS_KEY=S3SecretOps! AWS_DEFAULT_REGION=ap-east-1 S3_ENDPOINT=https://s3.internal.example.com bucket=artifacts-release", expectedType: "s3", expectedCluster: .objectStorageCredential),
            GeneratedSample(label: "minio-kv", text: "access_key=deploy-artifacts-ak secret_key=DeploySecret#2026 endpoint=https://minio.internal bucket=build-cache region=cn-east-1", expectedType: "s3", expectedCluster: .objectStorageCredential),
            GeneratedSample(label: "oss-provider", text: "provider=aws access_key=AKIADEPLOY01 secret_key=DeployAWS#2026 endpoint=https://s3-us.internal bucket=release-assets region=us-east-1", expectedType: "s3", expectedCluster: .objectStorageCredential),
            GeneratedSample(label: "s3-endpoint-host", text: "bucket=infra-backups s3_endpoint=https://minio-prod.internal aws_access_key_id=MINIODEPLOY aws_secret_access_key=MinioDeploy!2026 aws_default_region=cn-hangzhou", expectedType: "s3", expectedCluster: .objectStorageCredential),
            GeneratedSample(label: "storage-note", text: "endpoint=https://oss.internal.example.com bucket=media-prod access_key=oss-media-ak secret_key=OssMedia#2026 provider=aliyun region=cn-shanghai", expectedType: "s3", expectedCluster: .objectStorageCredential),

            GeneratedSample(label: "kafka-sasl", text: #"brokers=kafka-1.internal:9092,kafka-2.internal:9092 sasl.username="audit_pipeline" sasl.password="KafkaAudit!2026" mechanism=SCRAM-SHA-512 topic=audit.events env=prod"#, expectedType: "kafka", expectedCluster: .messageQueueCredential),
            GeneratedSample(label: "kafka-bootstrap", text: "bootstrap_servers=broker-a.internal:9092,broker-b.internal:9092 username=etl_consumer sasl_password=ETLConsumer#2026 topic=etl.jobs kafka cluster=prod", expectedType: "kafka", expectedCluster: .messageQueueCredential),
            GeneratedSample(label: "kafka-plain", text: "kafka brokers=stream-a.internal:9092,stream-b.internal:9092 username=stream_ro password=StreamRO#2026 mechanism=PLAIN topic=stream.events env=prod", expectedType: "kafka", expectedCluster: .messageQueueCredential),
            GeneratedSample(label: "kafka-stage", text: "brokers=stage-kafka.internal:9092 sasl_username=stage_consumer sasl_password=StageKafka#2026 mechanism=SCRAM-SHA-256 topic=metrics.ingest env=staging", expectedType: "kafka", expectedCluster: .messageQueueCredential),
            GeneratedSample(label: "kafka-bootstrap-short", text: "bootstrap=ops-kafka.internal:9092 user=ops_ro password=OpsKafka#2026 topic=ops.audit kafka env=ops", expectedType: "kafka", expectedCluster: .messageQueueCredential),

            GeneratedSample(label: "github-account", text: "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod", expectedType: "account", expectedCluster: .humanAccountLogin),
            GeneratedSample(label: "gitlab-account", text: "account=gitlab-ci-bot email=ci-bot@example.com passwd=GitLabCI!2026 service=GitLab url=https://gitlab.example.com", expectedType: "account", expectedCluster: .humanAccountLogin),
            GeneratedSample(label: "harbor-robot", text: "service=Harbor username=robot$deploy password=HarborRobot#2026 url=https://harbor.internal project=release-images", expectedType: "account", expectedCluster: .humanAccountLogin),
            GeneratedSample(label: "jenkins-login", text: "service=Jenkins username=builder-bot password=JenkinsBot#2026 url=https://jenkins.internal env=prod", expectedType: "account", expectedCluster: .humanAccountLogin),
            GeneratedSample(label: "grafana-login", text: "service=Grafana account=ops-oncall email=ops-oncall@example.com password=GrafanaOncall#2026 url=https://grafana.internal env=prod", expectedType: "account", expectedCluster: .humanAccountLogin),
            GeneratedSample(label: "argocd-login", text: "service=ArgoCD account=deploy-bot password=ArgoDeploy#2026 url=https://argocd.internal env=prod", expectedType: "account", expectedCluster: .humanAccountLogin),
            GeneratedSample(label: "sonarqube-login", text: "service=SonarQube username=quality-bot password=SonarBot#2026 url=https://sonar.internal env=staging", expectedType: "account", expectedCluster: .humanAccountLogin),
            GeneratedSample(label: "jira-login", text: "service=Jira username=ops-admin password=JiraAdmin#2026 url=https://jira.internal env=prod", expectedType: "account", expectedCluster: .humanAccountLogin),
            GeneratedSample(label: "gitea-login", text: "service=Gitea account=mirror-bot email=mirror@example.com password=GiteaMirror#2026 url=https://gitea.internal", expectedType: "account", expectedCluster: .humanAccountLogin),
            GeneratedSample(label: "slack-login", text: "service=Slack account=ops.workspace@example.com password=SlackOps#2026 url=https://workspace.slack.com env=prod", expectedType: "account", expectedCluster: .humanAccountLogin),

            GeneratedSample(label: "aliyun-aksk", text: "provider=aliyun ak=LTAI5TEXAMPLE sk=AliyunSK#2026 scope=oss-prod region=cn-shanghai", expectedType: "aksk", expectedCluster: .cloudAccessPair),
            GeneratedSample(label: "tencent-aksk", text: "provider=tencent access_key=TCloudAK001 secret_key=TCloudSecret!2026 project=cos-backup region=ap-shanghai", expectedType: "aksk", expectedCluster: .cloudAccessPair),
            GeneratedSample(label: "aws-aksk", text: "provider=aws access_key=AKIAOPS987 secret_key=AwsOpsSecret#2026 scope=iam-ops region=us-west-2", expectedType: "aksk", expectedCluster: .cloudAccessPair),
            GeneratedSample(label: "gcp-aksk", text: "provider=gcp ak=GCPAK0001 sk=GCPSK#2026 scope=artifact-registry region=asia-east1", expectedType: "aksk", expectedCluster: .cloudAccessPair),
            GeneratedSample(label: "azure-aksk", text: "provider=azure access_key=AZUREOPS01 secret_key=AzureOps#2026 project=blob-backup region=eastasia", expectedType: "aksk", expectedCluster: .cloudAccessPair),

            GeneratedSample(label: "amqp-uri-payments", text: "amqp://rabbit_user:RabbitMQ!2026@mq-prod.internal:5672/prod-vhost service=payments queue=settlement env=prod", expectedType: "custom", expectedCluster: .messageQueueCredential),
            GeneratedSample(label: "rabbitmq-kv-stage", text: "host=mq-stage.internal port=5672 username=ops password=RabbitStage#2026 vhost=stage engine=rabbitmq queue=jobs env=stage", expectedType: "custom", expectedCluster: .messageQueueCredential),
            GeneratedSample(label: "rabbitmq-inline", text: "rabbitmq username=alerts password=RabbitAlert#2026 host=mq-alerts.internal port=5672 vhost=alerts queue=notify env=prod", expectedType: "custom", expectedCluster: .messageQueueCredential),
            GeneratedSample(label: "amqp-orders", text: "amqp://order_user:OrderMQ#2026@mq-orders.internal:5672/orders-vhost service=orders queue=order.created env=prod", expectedType: "custom", expectedCluster: .messageQueueCredential),
            GeneratedSample(label: "rabbitmq-billing", text: "engine=rabbitmq host=mq-billing.internal port=5672 username=billing password=BillingMQ#2026 vhost=billing queue=invoice.generated env=prod", expectedType: "custom", expectedCluster: .messageQueueCredential),

            GeneratedSample(label: "service-endpoint-token", text: "endpoint=https://vault.internal username=ops-bot token=VaultToken#2026 provider=internal env=prod", expectedType: "custom", expectedCluster: .serviceEndpointSecret),
            GeneratedSample(label: "service-endpoint-password", text: "host=api.internal username=automation password=ApiAutomation#2026 provider=platform env=prod", expectedType: "custom", expectedCluster: .serviceEndpointSecret),
            GeneratedSample(label: "service-endpoint-url", text: "url=https://registry.internal username=robot password=RegistryRobot#2026 provider=harbor env=prod", expectedType: "custom", expectedCluster: .serviceEndpointSecret),
            GeneratedSample(label: "service-endpoint-login", text: "endpoint=https://nexus.internal login=artifact-ro secret=NexusRO#2026 service=nexus env=prod", expectedType: "account", expectedCluster: .serviceEndpointSecret),
            GeneratedSample(label: "service-endpoint-api", text: "host=consul.internal user=ops password=ConsulOps#2026 service=consul env=prod", expectedType: "account", expectedCluster: .serviceEndpointSecret)
        ]
    }

    func testSignInRequiresCredentials() {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())
        model.setAuthenticated(false)

        model.signIn("", "")

        XCTAssertFalse(model.isAuthenticated)
        XCTAssertEqual(model.statusMessage, "Enter username and password")
    }

    func testOfflineSearchUsesSeededRecords() async {
        let model = SecretBoxAppModel(
            environment: ["SECRETBOX_UI_TEST": "1"],
            defaults: defaults,
            recordStore: InMemoryRecordStore()
        )

        model.searchQuery = "billing"
        await model.searchPasswords()

        XCTAssertEqual(model.searchResults.count, 1)
        XCTAssertEqual(model.searchResults.first?.title, "Billing Postgres")
        XCTAssertEqual(model.selectedSearchRecord?.recordType, "database")
    }

    func testLegacyDefaultsRecordsMigrateIntoStore() throws {
        let legacyRecord = VaultRecord(
            id: "legacy-1",
            itemType: "account",
            templateType: nil,
            name: "Legacy Entry",
            subtitle: nil,
            notes: "stored by an older build",
            tags: [],
            fields: [],
            passwordHash: "hash",
            passwordFingerprint: "fp",
            primarySecret: "secret",
            matchReason: nil
        )
        defaults.set(try JSONEncoder().encode([legacyRecord]), forKey: localRecordsKey)

        let store = InMemoryRecordStore()
        let model = SecretBoxAppModel(defaults: defaults, recordStore: store)

        XCTAssertEqual(model.localRecords.map(\.id), ["legacy-1"])
        XCTAssertNil(defaults.data(forKey: localRecordsKey), "legacy plaintext blob should be removed after migration")
        XCTAssertEqual(store.loadData()?.count, try? JSONEncoder().encode([legacyRecord]).count)
    }

    func testDeleteRecordRemovesPersistsAndClearsSelection() async throws {
        let store = InMemoryRecordStore()
        let model = SecretBoxAppModel(
            environment: ["SECRETBOX_SKIP_NETWORK": "1"],
            defaults: defaults,
            recordStore: store
        )
        model.pastedText = "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod"
        await model.saveFromPastedText()

        let record = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(model.localRecords.count, 1)

        model.deleteRecord(id: record.id)

        XCTAssertTrue(model.localRecords.isEmpty)
        XCTAssertTrue(model.searchResults.isEmpty)
        XCTAssertNil(model.selectedSearchRecord)
        XCTAssertNil(model.latestSavedRecord)
        XCTAssertEqual(model.statusMessage, "Deleted \(record.name)")

        let persisted = try XCTUnwrap(store.loadData())
        XCTAssertEqual(try JSONDecoder().decode([VaultRecord].self, from: persisted).count, 0)
    }

    func testCapturedRecordsDefaultToNotAIShared() async {
        let model = SecretBoxAppModel(
            environment: ["SECRETBOX_SKIP_NETWORK": "1"],
            defaults: defaults,
            recordStore: InMemoryRecordStore()
        )
        model.pastedText = "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod"
        await model.saveFromPastedText()

        XCTAssertEqual(model.latestSavedRecord?.aiReadable, false, "records must default to not shared with AI")
    }

    func testEditorOptInPersistsAIReadableFlag() async {
        let store = InMemoryRecordStore()
        let model = SecretBoxAppModel(
            environment: ["SECRETBOX_SKIP_NETWORK": "1"],
            defaults: defaults,
            recordStore: store
        )
        model.recordPermissions.aiAccess = .metadataAndTools
        model.recordTitle = "Shared Redis"
        model.recordPassword = "redis-secret"
        model.selectType("redis")
        model.updateField("host", value: "redis.internal")

        await model.saveRecord()

        XCTAssertEqual(model.latestSavedRecord?.aiReadable, true)

        let reloaded = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore(data: store.loadData()))
        XCTAssertEqual(reloaded.localRecords.first?.aiReadable, true, "flag must survive reload")
    }

    func testSetAIReadableTogglesAndPersists() async throws {
        let store = InMemoryRecordStore()
        let model = SecretBoxAppModel(
            environment: ["SECRETBOX_SKIP_NETWORK": "1"],
            defaults: defaults,
            recordStore: store
        )
        model.pastedText = "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod"
        await model.saveFromPastedText()

        let record = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(record.aiReadable, false)

        model.setAIReadable(id: record.id, allowed: true)
        XCTAssertEqual(model.localRecords.first?.aiReadable, true)
        XCTAssertEqual(model.searchResults.first(where: { $0.id == record.id })?.aiReadable, true)

        model.setAIReadable(id: record.id, allowed: false)
        XCTAssertEqual(model.localRecords.first?.aiReadable, false, "disable must persist an explicit false")

        let reloaded = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore(data: store.loadData()))
        XCTAssertEqual(reloaded.localRecords.first?.aiReadable, false, "disable must persist")
    }

    func testAIReferenceIdentifiesRecordWithoutPlaintext() async throws {
        let model = SecretBoxAppModel(
            environment: ["SECRETBOX_SKIP_NETWORK": "1"],
            defaults: defaults,
            recordStore: InMemoryRecordStore()
        )
        model.pastedText = "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod"
        await model.saveFromPastedText()

        let record = try XCTUnwrap(model.latestSavedRecord)
        let reference = record.aiAgentReference

        XCTAssertTrue(reference.contains("id=\"\(record.id)\""), "reference must carry the record id agents resolve by")
        XCTAssertTrue(reference.contains("name=\""), "reference should name the record")
        XCTAssertTrue(reference.contains("username=\"ops-bot@example.com\""))
        XCTAssertTrue(reference.contains("host=\"https://github.com\""))
        XCTAssertTrue(reference.contains("get_credential(record_id=\"\(record.id)\")"))
        XCTAssertTrue(reference.contains("copy_password(record_id=\"\(record.id)\")"))
        XCTAssertTrue(reference.contains("<secretbox-credential"))
        XCTAssertFalse(reference.contains("GhOpsBot@2026"), "the plaintext secret must never appear in the reference")
        XCTAssertFalse(reference.contains("password_hash"), "secret-classified fields must not leak into the reference")
    }

    func testAIReferenceEscapesMarkupInMetadata() {
        let record = VaultRecord(
            id: "esc-1",
            itemType: "secret",
            templateType: "redis",
            name: "Odd \"Prod\" <&> Cache",
            subtitle: nil,
            notes: "",
            tags: [],
            fields: [],
            passwordHash: "hash",
            passwordFingerprint: "fp",
            primarySecret: "super-secret-value",
            matchReason: nil
        )

        let reference = record.aiAgentReference

        XCTAssertTrue(reference.contains("name=\"Odd &quot;Prod&quot; &lt;&amp;&gt; Cache\""))
        XCTAssertFalse(reference.contains("Odd \"Prod\""))
        XCTAssertFalse(reference.contains("super-secret-value"))
    }

    func testCopyAIReferencePlacesReferenceOnClipboard() async throws {
        let model = SecretBoxAppModel(
            environment: ["SECRETBOX_SKIP_NETWORK": "1"],
            defaults: defaults,
            recordStore: InMemoryRecordStore()
        )
        model.recordTitle = "Redis Ops"
        model.recordPassword = "redis-secret-9"
        model.selectType("redis")
        model.updateField("host", value: "redis.internal")
        await model.saveRecord()
        let record = try XCTUnwrap(model.latestSavedRecord)

        model.copyAIReference(for: record)

        XCTAssertEqual(PlatformClipboard.string, record.aiAgentReference)
        XCTAssertEqual(model.statusMessage, "AI reference copied for \(record.name)")
        XCTAssertFalse(PlatformClipboard.string?.contains("redis-secret-9") ?? true, "clipboard must hold the reference, not the secret")
    }

    func testOfflineSaveCreatesLocalRecord() async {
        let model = SecretBoxAppModel(
            environment: ["SECRETBOX_SKIP_NETWORK": "1"],
            defaults: defaults,
            recordStore: InMemoryRecordStore()
        )
        model.recordTitle = "Redis Ops"
        model.recordPassword = "redis-secret"
        model.recordNote = "Redis production auth"
        model.recordUsername = "redis_admin"
        model.selectType("redis")
        model.updateField("host", value: "redis.internal")
        model.updateField("port", value: "6379")

        await model.saveRecord()

        XCTAssertEqual(model.latestSavedRecord?.title, "Redis Ops")
        XCTAssertEqual(model.latestSavedRecord?.recordType, "redis")
        XCTAssertEqual(model.latestSavedRecord?.password, "redis-secret")
        XCTAssertEqual(model.selectedSearchRecord?.title, "Redis Ops")
        XCTAssertEqual(model.searchResults.first?.title, "Redis Ops")
    }

    func testDefaultLaunchUsesLocalOnlyMode() async {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        XCTAssertFalse(model.serverEnabled)

        await model.bootstrap()

        XCTAssertEqual(model.statusMessage, "Offline mode")
        XCTAssertTrue(model.searchResults.isEmpty)
        XCTAssertNil(model.selectedSearchRecord)
    }

    func testLocalOnlyPastedTextSaveUpdatesVisibleResults() async {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())
        XCTAssertFalse(model.serverEnabled)

        model.pastedText = "redis://default:LocalRedis#2026@redis-prod.internal:6379/0\n env=prod \\\n service=order-cache"
        await model.saveFromPastedText()

        XCTAssertEqual(model.localRecords.count, 1)
        XCTAssertEqual(model.latestSavedRecord?.recordType, "redis")
        XCTAssertEqual(model.selectedSearchRecord?.recordType, "redis")
        XCTAssertEqual(model.searchResults.first?.recordType, "redis")
        XCTAssertEqual(model.statusMessage, "Saved captured item")

        model.searchQuery = "order-cache"
        await model.searchPasswords()

        XCTAssertEqual(model.searchResults.count, 1)
        XCTAssertEqual(model.searchResults.first?.recordType, "redis")
    }

    func testDisablingServerFallsBackToLocalRecords() async {
        let model = SecretBoxAppModel(
            environment: ["SECRETBOX_SKIP_NETWORK": "1"],
            defaults: defaults,
            recordStore: InMemoryRecordStore()
        )
        model.recordTitle = "Kafka Ops"
        model.recordPassword = "kafka-secret"
        model.recordNote = "Kafka production auth"
        model.recordUsername = "kafka_admin"
        model.selectType("kafka")
        model.updateField("brokers", value: "broker-a:9092,broker-b:9092")

        await model.saveRecord()
        XCTAssertEqual(model.localRecords.count, 1)

        model.searchResults = []
        model.selectedSearchRecord = nil
        model.serverEnabled = true
        model.serverEnabled = false

        XCTAssertEqual(model.statusMessage, "Local-only mode")
        XCTAssertEqual(model.searchResults.count, 1)
        XCTAssertEqual(model.selectedSearchRecord?.title, "Kafka Ops")
        XCTAssertEqual(model.latestSavedRecord?.title, "Kafka Ops")
    }

    func testLocalSearchPrioritizesHostAndURLMatches() async {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod"
        await model.saveFromPastedText()
        model.pastedText = "service=Mirror username=mirror@example.com password=MirrorBot@2026 notes=github helper env=prod"
        await model.saveFromPastedText()

        model.searchQuery = "github.com"
        await model.searchPasswords()

        XCTAssertEqual(model.searchResults.first?.fieldMap["url"], "https://github.com")
        XCTAssertEqual(model.selectedSearchRecord?.fieldMap["url"], "https://github.com")
    }

    func testLocalSearchPrioritizesLabelMatchesOverDescriptionMatches() async {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "redis://default:RedisProd#2026@redis-prod.internal:6379/0 env=prod service=order-cache"
        await model.saveFromPastedText()
        model.recordTitle = "Notes Only"
        model.recordPassword = "secret"
        model.recordNote = "Used by order-cache migration runbook"
        model.recordUsername = "ops"
        model.selectType("custom")
        await model.saveRecord()

        model.searchQuery = "order-cache"
        await model.searchPasswords()

        XCTAssertEqual(model.searchResults.first?.fieldMap["label"], "order-cache")
        XCTAssertEqual(model.selectedSearchRecord?.fieldMap["label"], "order-cache")
    }

    func testLocalSearchMatchesClusterLabel() async throws {
        let customRecord = VaultRecord(
            id: "cluster-label-record",
            itemType: "secret",
            templateType: "custom",
            clusterID: CredentialClusterID.messageQueueCredential.rawValue,
            clusterConfidence: 0.82,
            signals: [
                VaultSignal(category: .locator, name: "host", value: "mq-prod.internal", normalizedValue: "mq-prod.internal"),
                VaultSignal(category: .resource, name: "vhost", value: "prod-vhost", normalizedValue: "prod-vhost")
            ],
            clusterLabel: "AMQP Queue Access",
            lastOrganizedAt: Date(),
            name: "Payments Queue",
            subtitle: nil,
            notes: "mq secret",
            tags: ["custom", "cluster:amqp-queue"],
            fields: [
                VaultField(key: "host", label: "Host", value: "mq-prod.internal", valueType: "text", semantic: "host", hidden: false, section: "Connection", order: 0),
                VaultField(key: "vhost", label: "VHost", value: "prod-vhost", valueType: "text", semantic: "vhost", hidden: false, section: "Connection", order: 1)
            ],
            passwordHash: "hash",
            passwordFingerprint: "fp",
            primarySecret: "secret",
            matchReason: nil
        )
        defaults.set(try JSONEncoder().encode([customRecord]), forKey: localRecordsKey)

        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())
        model.searchQuery = "amqp"
        await model.searchPasswords()

        XCTAssertEqual(model.searchResults.first?.id, customRecord.id)
        XCTAssertEqual(model.searchResults.first?.clusterSchemaDefinition.fields.first?.label, "Transport")
    }

    func testClusterBrowserSummariesGroupAndFilterRecords() async {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod"
        await model.saveFromPastedText()
        model.pastedText = "account=gitlab-ci-bot email=ci-bot@example.com passwd=GitLabCI!2026 service=GitLab url=https://gitlab.example.com"
        await model.saveFromPastedText()

        let clusters = model.clusterBrowserSummaries
        XCTAssertTrue(clusters.contains(where: { $0.label == "GitHub Account Access" }))
        XCTAssertTrue(clusters.contains(where: { $0.label == "GitLab Account Access" }))

        model.browseCluster("GitHub Account Access")

        XCTAssertEqual(model.browserTitle, "GitHub Account Access")
        XCTAssertEqual(model.filteredResults.count, 1)
        XCTAssertEqual(model.filteredResults.first?.clusterLabel, "GitHub Account Access")
    }

    func testClusterBrowserSortsRecordsByClusterSchema() async {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "DATABASE_URL=postgresql://billing_admin:PgBilling%232026@db-zeta.internal:5432/billing env=prod service=billing"
        await model.saveFromPastedText()
        model.pastedText = "DATABASE_URL=postgresql://audit_admin:PgAudit%232026@db-alpha.internal:5432/audit env=prod service=audit"
        await model.saveFromPastedText()

        model.browseCluster("Postgres Database Access")

        XCTAssertEqual(model.filteredResults.count, 2)
        XCTAssertEqual(model.filteredResults.map { $0.fieldMap["host"] ?? "" }, ["db-alpha.internal", "db-zeta.internal"])
    }

    func testClusterBrowserCanSortByName() async {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod"
        await model.saveFromPastedText()
        model.pastedText = "account=gitlab-ci-bot email=ci-bot@example.com passwd=GitLabCI!2026 service=GitLab url=https://gitlab.example.com"
        await model.saveFromPastedText()

        model.clusterBrowserSortMode = .name

        XCTAssertEqual(model.clusterBrowserSummaries.map(\.label), ["GitHub Account Access", "GitLab Account Access"])
    }

    func testClusterBrowserCanSortByRecentActivity() async {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod"
        await model.saveFromPastedText()
        model.pastedText = "amqp://rabbit_user:RabbitMQ!2026@mq-stage.internal:5672/stage service=payments queue=jobs env=stage"
        await model.saveFromPastedText()

        model.clusterBrowserSortMode = .recent

        XCTAssertEqual(model.clusterBrowserSummaries.map(\.label), ["AMQP Queue Access", "GitHub Account Access"])
    }

    func testOpenSearchFromMenuBarSelectsLatestSavedLocalRecord() async {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())
        XCTAssertFalse(model.serverEnabled)

        model.pastedText = "redis://default:LocalRedis#2026@redis-prod.internal:6379/0 env=prod service=order-cache"
        await model.saveFromPastedText()
        XCTAssertEqual(model.latestSavedRecord?.title, "REDIS order-cache")

        model.browserFilterID = "database"
        model.searchResults = []
        model.selectedSearchRecord = nil
        let previousFocusToken = model.searchFocusToken

        model.openSearchFromMenuBar()

        XCTAssertEqual(model.browserFilterID, "all")
        XCTAssertEqual(model.searchFocusToken, previousFocusToken + 1)
        XCTAssertEqual(model.selectedSearchRecord?.id, model.latestSavedRecord?.id)
        XCTAssertEqual(model.selectedSearchRecord?.title, "REDIS order-cache")
        XCTAssertEqual(model.searchResults.first?.id, model.latestSavedRecord?.id)
    }

    func testOfflinePastedRedisTextExtractsFieldsAndRedactsSecret() async throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "redis://default:LocalRedis#2026@redis-prod.internal:6379/0 env=prod service=order-cache"
        await model.saveFromPastedText()

        let record = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(record.recordType, "redis")
        XCTAssertEqual(record.password, "LocalRedis#2026")
        XCTAssertEqual(record.fieldMap["host"], "redis-prod.internal")
        XCTAssertEqual(record.fieldMap["port"], "6379")
        XCTAssertEqual(record.fieldMap["db"], "0")
        XCTAssertEqual(record.fieldMap["source_excerpt"], "redis://default:[REDACTED]@redis-prod.internal:6379/0 env=prod service=order-cache")
        XCTAssertEqual(record.clusterID, CredentialClusterID.cacheCredential.rawValue)
        XCTAssertTrue(record.signals?.contains(where: { $0.category == .locator && $0.name == "host" && $0.normalizedValue == "redis-prod.internal" }) == true)
    }

    func testOfflinePastedDatabaseTextExtractsConnectionFields() async throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "DATABASE_URL=postgresql://billing_admin:PgBilling%232026@billing-db.internal:5432/billing env=prod service=reconciliation"
        await model.saveFromPastedText()

        let record = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(record.recordType, "database")
        XCTAssertEqual(record.password, "PgBilling%232026")
        XCTAssertEqual(record.fieldMap["engine"], "postgres")
        XCTAssertEqual(record.fieldMap["host"], "billing-db.internal")
        XCTAssertEqual(record.fieldMap["port"], "5432")
        XCTAssertEqual(record.fieldMap["database"], "billing")
        XCTAssertEqual(record.fieldMap["username"], "billing_admin")
    }

    func testOfflinePastedS3TextExtractsCredentialFields() async throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "AWS_ACCESS_KEY_ID=AKIAOPS123 AWS_SECRET_ACCESS_KEY=S3SecretOps! AWS_DEFAULT_REGION=ap-east-1 S3_ENDPOINT=https://s3.internal.example.com bucket=artifacts-release"
        await model.saveFromPastedText()

        let record = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(record.recordType, "s3")
        XCTAssertEqual(record.password, "S3SecretOps!")
        XCTAssertEqual(record.fieldMap["access_key"], "AKIAOPS123")
        XCTAssertEqual(record.fieldMap["region"], "ap-east-1")
        XCTAssertEqual(record.fieldMap["endpoint"], "https://s3.internal.example.com")
        XCTAssertEqual(record.fieldMap["bucket"], "artifacts-release")
    }

    func testOfflinePastedKafkaTextExtractsSASLFields() async throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = #"brokers=kafka-1.internal:9092,kafka-2.internal:9092 sasl.username="audit_pipeline" sasl.password="KafkaAudit!2026" mechanism=SCRAM-SHA-512 topic=audit.events env=prod"#
        await model.saveFromPastedText()

        let record = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(record.recordType, "kafka")
        XCTAssertEqual(record.password, "KafkaAudit!2026")
        XCTAssertEqual(record.fieldMap["brokers"], "kafka-1.internal:9092,kafka-2.internal:9092")
        XCTAssertEqual(record.fieldMap["username"], "audit_pipeline")
        XCTAssertEqual(record.fieldMap["mechanism"], "SCRAM-SHA-512")
        XCTAssertEqual(record.fieldMap["topic"], "audit.events")
    }

    func testOfflinePastedAKSKTextExtractsProviderFields() async throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "provider=aliyun ak=LTAI5TEXAMPLE sk=AliyunSK#2026 scope=oss-prod region=cn-shanghai"
        await model.saveFromPastedText()

        let record = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(record.recordType, "aksk")
        XCTAssertEqual(record.password, "AliyunSK#2026")
        XCTAssertEqual(record.fieldMap["provider"], "aliyun")
        XCTAssertEqual(record.fieldMap["access_key"], "LTAI5TEXAMPLE")
        XCTAssertEqual(record.fieldMap["scope"], "oss-prod")
        XCTAssertEqual(record.fieldMap["region"], "cn-shanghai")
    }

    func testOfflinePastedRabbitMQTextExtractsCustomConnectionFields() async throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "amqp://rabbit_user:RabbitMQ!2026@mq-prod.internal:5672/prod-vhost service=payments queue=settlement"
        await model.saveFromPastedText()

        let record = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(record.recordType, "custom")
        XCTAssertEqual(record.password, "RabbitMQ!2026")
        XCTAssertEqual(record.fieldMap["username"], "rabbit_user")
        XCTAssertEqual(record.fieldMap["host"], "mq-prod.internal")
        XCTAssertEqual(record.fieldMap["port"], "5672")
        XCTAssertEqual(record.fieldMap["vhost"], "prod-vhost")
        XCTAssertEqual(record.fieldMap["source_excerpt"], "amqp://rabbit_user:[REDACTED]@mq-prod.internal:5672/prod-vhost service=payments queue=settlement")
    }

    func testOfflinePastedMongoDBTextExtractsDatabaseFields() async throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "mongodb://report_user:MongoReport%402026@mongo-01.internal:27017/reports?replicaSet=rs0 env=prod team=data"
        await model.saveFromPastedText()

        let record = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(record.recordType, "database")
        XCTAssertEqual(record.password, "MongoReport%402026")
        XCTAssertEqual(record.fieldMap["engine"], "mongodb")
        XCTAssertEqual(record.fieldMap["host"], "mongo-01.internal")
        XCTAssertEqual(record.fieldMap["port"], "27017")
        XCTAssertEqual(record.fieldMap["database"], "reports")
        XCTAssertEqual(record.fieldMap["username"], "report_user")
    }

    func testOfflinePastedGitHubAccountTextExtractsAccountFields() async throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod"
        await model.saveFromPastedText()

        let record = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(record.recordType, "account")
        XCTAssertEqual(record.password, "GhOpsBot@2026")
        XCTAssertEqual(record.fieldMap["service"], "GitHub")
        XCTAssertEqual(record.fieldMap["account"], "ops-bot@example.com")
        XCTAssertEqual(record.fieldMap["url"], "https://github.com")
        XCTAssertEqual(record.fieldMap["label"], "GitHub")
        XCTAssertEqual(record.fieldMap["env"], "prod")
    }

    func testOfflinePastedHarborAccountTextExtractsProjectFields() async throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "service=Harbor username=robot$deploy password=HarborRobot#2026 url=https://harbor.internal project=release-images"
        await model.saveFromPastedText()

        let record = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(record.recordType, "account")
        XCTAssertEqual(record.password, "HarborRobot#2026")
        XCTAssertEqual(record.fieldMap["service"], "Harbor")
        XCTAssertEqual(record.fieldMap["account"], "robot$deploy")
        XCTAssertEqual(record.fieldMap["url"], "https://harbor.internal")
    }

    func testOfflinePastedGitLabAccountTextExtractsAccountFields() async throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "account=gitlab-ci-bot email=ci-bot@example.com passwd=GitLabCI!2026 service=GitLab url=https://gitlab.example.com"
        await model.saveFromPastedText()

        let record = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(record.recordType, "account")
        XCTAssertEqual(record.password, "GitLabCI!2026")
        XCTAssertEqual(record.fieldMap["service"], "GitLab")
        XCTAssertEqual(record.fieldMap["account"], "gitlab-ci-bot")
        XCTAssertEqual(record.fieldMap["url"], "https://gitlab.example.com")
    }

    func testPastedSecretPreviewShowsDetectedTypeAndHighlights() throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod"

        let preview = try XCTUnwrap(model.pastedSecretPreview)
        XCTAssertEqual(preview.templateType, "account")
        XCTAssertEqual(preview.clusterDecision.clusterID, .humanAccountLogin)
        XCTAssertGreaterThan(preview.clusterDecision.confidence, 0.4)
        XCTAssertTrue(preview.signals.contains(where: { $0.category == .locator && $0.name == "url" && $0.normalizedValue == "github.com" }))
        XCTAssertTrue(preview.tags.contains("url:github.com"))
        XCTAssertTrue(preview.tags.contains("label:GitHub"))
        XCTAssertTrue(preview.tags.contains("env:prod"))
        XCTAssertTrue(preview.tags.contains("secret:\u{2022}\u{2022}\u{2022}\u{2022}2026"))
        XCTAssertTrue(preview.hasSecret)
        XCTAssertTrue(preview.highlights.contains("Service: GitHub"))
    }

    func testPastedSecretPreviewExposesEditableFields() throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "redis://default:RedisProd#2026@redis-prod.internal:6379/0 env=prod service=order-cache"

        let preview = try XCTUnwrap(model.pastedSecretPreview)
        XCTAssertTrue(preview.editableFields.contains(where: { $0.key == "username" && $0.value == "default" }))
        XCTAssertTrue(preview.editableFields.contains(where: { $0.key == "host" && $0.value == "redis-prod.internal" }))
        XCTAssertTrue(preview.editableFields.contains(where: { $0.key == "port" && $0.value == "6379" }))
    }

    func testPastedSecretPreviewReflectsTypeOverride() throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod"
        model.pastedTypeOverride = "custom"

        let preview = try XCTUnwrap(model.pastedSecretPreview)
        XCTAssertEqual(preview.templateType, "custom")
        XCTAssertTrue(preview.tags.contains("label:GitHub"))
    }

    func testPastedSecretPreviewCarriesSchemaRelevantFields() throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "DATABASE_URL=postgresql://billing_admin:PgBilling%232026@billing-db.internal:5432/billing env=prod service=reconciliation"

        let preview = try XCTUnwrap(model.pastedSecretPreview)
        XCTAssertEqual(preview.clusterDecision.clusterID, .relationalDBCredential)
        XCTAssertTrue(preview.editableFields.contains(where: { $0.key == "engine" && $0.value == "postgres" }))
        XCTAssertTrue(preview.editableFields.contains(where: { $0.key == "host" && $0.value == "billing-db.internal" }))
        XCTAssertTrue(preview.editableFields.contains(where: { $0.key == "database" && $0.value == "billing" }))
    }

    func testPastedSecretPreviewPrioritizesLocatorAndResourceTags() throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "DATABASE_URL=postgresql://billing_admin:PgBilling%232026@billing-db.internal:5432/billing env=prod service=reconciliation"

        let preview = try XCTUnwrap(model.pastedSecretPreview)
        XCTAssertTrue(preview.tags.contains("host:billing-db.internal"))
        XCTAssertTrue(preview.tags.contains("label:reconciliation"))
        XCTAssertTrue(preview.tags.contains("db:billing"))
        XCTAssertTrue(preview.tags.contains("env:prod"))
        XCTAssertTrue(preview.tags.contains("engine:postgres"))
        XCTAssertTrue(preview.tags.contains("secret:\u{2022}\u{2022}\u{2022}\u{2022}2026"))
    }

    func testCustomPastedPreviewCarriesQueueAndEnvironmentContext() throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "amqp://rabbit_user:RabbitMQ!2026@mq-prod.internal:5672/prod-vhost service=payments queue=settlement env=prod"

        let preview = try XCTUnwrap(model.pastedSecretPreview)
        XCTAssertTrue(preview.tags.contains("host:mq-prod.internal"))
        XCTAssertTrue(preview.tags.contains("label:payments"))
        XCTAssertTrue(preview.tags.contains("topic:settlement"))
        XCTAssertTrue(preview.tags.contains("env:prod") || preview.tags.contains("vhost:prod-vhost"))
        XCTAssertTrue(preview.tags.contains("secret:\u{2022}\u{2022}\u{2022}\u{2022}2026"))
    }

    func testPastedPreviewOverridesAreAppliedOnSave() async throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod"
        model.pastedTypeOverride = "custom"
        model.pastedTitleOverride = "Ops Bot Override"
        model.pastedNoteOverride = "Manual summary"

        await model.saveFromPastedText()

        let record = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(record.recordType, "custom")
        XCTAssertEqual(record.title, "Ops Bot Override")
        XCTAssertEqual(record.description, "Manual summary")
    }

    func testPastedFieldOverridesAreAppliedOnSave() async throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "redis://default:RedisProd#2026@redis-prod.internal:6379/0 env=prod service=order-cache"
        model.pastedFieldOverrides["host"] = "redis-override.internal"
        model.pastedFieldOverrides["username"] = "override-user"

        await model.saveFromPastedText()

        let record = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(record.recordType, "redis")
        XCTAssertEqual(record.fieldMap["host"], "redis-override.internal")
        XCTAssertEqual(record.fieldMap["username"], "override-user")
    }

    func testPastedPreviewOverridesResetAfterSave() async throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod"
        model.pastedTypeOverride = "custom"
        model.pastedTitleOverride = "Ops Bot Override"
        model.pastedNoteOverride = "Manual summary"
        model.pastedFieldOverrides["account"] = "override-account"

        await model.saveFromPastedText()

        XCTAssertEqual(model.pastedText, "")
        XCTAssertEqual(model.pastedTypeOverride, "")
        XCTAssertEqual(model.pastedTitleOverride, "")
        XCTAssertEqual(model.pastedNoteOverride, "")
        XCTAssertEqual(model.pastedFieldOverrides, [:])
        XCTAssertNil(model.pastedSecretPreview)
    }

    func testBeginEditingUsesClusterSignalsForContextGroups() async throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod"
        await model.saveFromPastedText()

        let record = try XCTUnwrap(model.latestSavedRecord)
        model.beginEditing(record)

        XCTAssertEqual(model.editingClusterID, CredentialClusterID.humanAccountLogin.rawValue)
        XCTAssertTrue(model.editingSignals.contains(where: { $0.name == "url" && $0.normalizedValue == "github.com" }))
        XCTAssertEqual(model.editingFieldGroups.first?.title, "Detected Context")
        XCTAssertTrue(model.editingFieldGroups.first?.keys.contains("url") == true)
        XCTAssertTrue(model.editingFieldGroups.first?.keys.contains("env") == true)
    }

    func testEditingAndSavingReclustersRecordFromAccountToObjectStorage() async throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        model.pastedText = "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod"
        await model.saveFromPastedText()

        let record = try XCTUnwrap(model.latestSavedRecord)
        model.beginEditing(record)
        model.recordTitle = "Artifacts Access"
        model.recordNote = "Object storage credential"
        model.recordUsername = ""
        model.recordFields["service"] = ""
        model.recordFields["account"] = ""
        model.recordFields["url"] = "https://s3.internal.example.com"
        model.recordFields["endpoint"] = "https://s3.internal.example.com"
        model.recordFields["bucket"] = "artifacts-prod"
        model.recordFields["access_key"] = "ops-artifact-ak"
        model.recordFields["region"] = "ap-east-1"
        model.recordFields["provider"] = "aws"
        model.recordPassword = "S3SecretOps!2026"

        await model.saveRecord()

        let updated = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(updated.recordType, "s3")
        XCTAssertEqual(updated.clusterID, CredentialClusterID.objectStorageCredential.rawValue)
        XCTAssertEqual(updated.fieldMap["bucket"], "artifacts-prod")
        XCTAssertTrue(updated.signals?.contains(where: { $0.name == "bucket" && $0.normalizedValue == "artifacts-prod" }) == true)
    }

    func testThresholdOrganizationRunsAfterTwentyCustomItems() async throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())

        for index in 0...20 {
            model.pastedText = "amqp://rabbit_user:RabbitMQ!2026@mq-\(index).internal:5672/prod-vhost service=payments queue=settlement-\(index) env=prod"
            await model.saveFromPastedText()
        }

        let summary = try XCTUnwrap(model.organizationSummary)
        XCTAssertEqual(summary.trigger, "threshold")
        XCTAssertEqual(summary.processedRecords, 21)
        XCTAssertEqual(summary.customRecords, 21)
        XCTAssertGreaterThanOrEqual(summary.generatedClusters, 1)
        XCTAssertNotNil(model.latestSavedRecord?.lastOrganizedAt)
        XCTAssertEqual(model.latestSavedRecord?.clusterLabel, "AMQP Queue Access")
    }

    func testPeriodicOrganizationRunsOnBootstrapWhenLastRunIsStale() async throws {
        defaults.set(3.0, forKey: organizationIntervalDaysKey)
        let staleDate = Date(timeIntervalSinceNow: -(4 * 24 * 60 * 60))
        defaults.set(staleDate, forKey: organizationLastRunKey)

        let seededRecord = VaultRecord(
            id: "stale-custom",
            itemType: "secret",
            templateType: "custom",
            clusterID: nil,
            clusterConfidence: nil,
            signals: nil,
            clusterLabel: nil,
            lastOrganizedAt: nil,
            name: "Payments MQ",
            subtitle: nil,
            notes: "amqp endpoint for payments",
            tags: ["custom"],
            fields: [
                VaultField(key: "host", label: "Host", value: "mq-prod.internal", valueType: "text", semantic: "host", hidden: false, section: "Connection", order: 0),
                VaultField(key: "vhost", label: "VHost", value: "prod-vhost", valueType: "text", semantic: "vhost", hidden: false, section: "Connection", order: 1),
                VaultField(key: "queue", label: "Queue", value: "settlement", valueType: "text", semantic: "queue", hidden: false, section: "Connection", order: 2),
            ],
            passwordHash: "hash",
            passwordFingerprint: "fingerprint",
            primarySecret: "RabbitMQ!2026",
            matchReason: nil
        )
        defaults.set(try JSONEncoder().encode([seededRecord]), forKey: localRecordsKey)

        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())
        await model.bootstrap()

        let summary = try XCTUnwrap(model.organizationSummary)
        XCTAssertEqual(summary.trigger, "periodic")
        XCTAssertEqual(model.organizationIntervalDays, 3)
        XCTAssertEqual(model.latestSavedRecord?.clusterLabel, "AMQP Queue Access")
        XCTAssertNotNil(model.latestSavedRecord?.lastOrganizedAt)
    }

    func testManualOrganizationPromotesStructuredCustomRecord() async throws {
        let customRecord = VaultRecord(
            id: "manual-custom",
            itemType: "secret",
            templateType: "custom",
            clusterID: nil,
            clusterConfidence: nil,
            signals: nil,
            clusterLabel: nil,
            lastOrganizedAt: nil,
            name: "Ops Bot",
            subtitle: nil,
            notes: "github automation account",
            tags: ["custom"],
            fields: [
                VaultField(key: "service", label: "Service", value: "GitHub", valueType: "text", semantic: "service", hidden: false, section: "Login", order: 0),
                VaultField(key: "account", label: "Account", value: "ops-bot@example.com", valueType: "text", semantic: "account", hidden: false, section: "Login", order: 1),
                VaultField(key: "url", label: "URL", value: "https://github.com", valueType: "url", semantic: "uri", hidden: false, section: "Login", order: 2),
            ],
            passwordHash: "hash",
            passwordFingerprint: "fingerprint",
            primarySecret: "GhOpsBot@2026",
            matchReason: nil
        )
        defaults.set(try JSONEncoder().encode([customRecord]), forKey: localRecordsKey)

        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())
        await model.runSmartOrganizationNow()

        let summary = try XCTUnwrap(model.organizationSummary)
        let updated = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(summary.trigger, "manual")
        XCTAssertEqual(updated.recordType, "account")
        XCTAssertEqual(updated.clusterID, CredentialClusterID.humanAccountLogin.rawValue)
        XCTAssertEqual(updated.clusterLabel, "GitHub Account Access")
    }

    func testDiverseFiftySampleSetPersistAndClassify() async throws {
        let model = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore())
        let samples = makeDiverseGeneratedSamples()

        for sample in samples {
            model.pastedText = sample.text
            await model.saveFromPastedText()
            XCTAssertEqual(model.latestSavedRecord?.recordType, sample.expectedType, sample.label)
            XCTAssertEqual(model.latestSavedRecord?.clusterID, sample.expectedCluster.rawValue, sample.label)
        }

        XCTAssertEqual(model.localRecords.count, 50)

        let countsByType = Dictionary(grouping: model.localRecords, by: \.recordType).mapValues(\.count)
        XCTAssertEqual(countsByType["redis"], 5)
        XCTAssertEqual(countsByType["database"], 10)
        XCTAssertEqual(countsByType["s3"], 5)
        XCTAssertEqual(countsByType["kafka"], 5)
        XCTAssertEqual(countsByType["account"], 12)
        XCTAssertEqual(countsByType["aksk"], 5)
        XCTAssertEqual(countsByType["custom"], 8)

        let countsByCluster = Dictionary(grouping: model.localRecords.compactMap(\.clusterID), by: { $0 }).mapValues(\.count)
        XCTAssertEqual(countsByCluster[CredentialClusterID.cacheCredential.rawValue], 5)
        XCTAssertEqual(countsByCluster[CredentialClusterID.relationalDBCredential.rawValue], 10)
        XCTAssertEqual(countsByCluster[CredentialClusterID.objectStorageCredential.rawValue], 5)
        XCTAssertEqual(countsByCluster[CredentialClusterID.messageQueueCredential.rawValue], 10)
        XCTAssertEqual(countsByCluster[CredentialClusterID.humanAccountLogin.rawValue], 10)
        XCTAssertEqual(countsByCluster[CredentialClusterID.cloudAccessPair.rawValue], 5)
        XCTAssertEqual(countsByCluster[CredentialClusterID.serviceEndpointSecret.rawValue], 5)

        XCTAssertTrue(model.localRecords.allSatisfy { $0.clusterID != nil && $0.clusterLabel != nil })
    }

    // MARK: - TOTP (two-step verification)

    private func makeOfflineModel(store: RecordStoring = InMemoryRecordStore(),
                                  reauthGate: (any ReauthGate)? = nil) -> SecretBoxAppModel {
        if let reauthGate {
            return SecretBoxAppModel(
                environment: ["SECRETBOX_SKIP_NETWORK": "1"],
                defaults: defaults,
                recordStore: store,
                reauthGate: reauthGate
            )
        }
        return SecretBoxAppModel(
            environment: ["SECRETBOX_SKIP_NETWORK": "1"],
            defaults: defaults,
            recordStore: store
        )
    }

    func testSaveRecordWithTOTPInputPersistsSeedAndSurvivesReload() async throws {
        let store = InMemoryRecordStore()
        let model = makeOfflineModel(store: store)
        model.recordTitle = "GitHub Ops"
        model.recordPassword = "GhOpsBot@2026"
        model.recordTOTPInput = "otpauth://totp/GitHub:ops-bot@example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&digits=8&period=60"

        await model.saveRecord()

        let saved = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(saved.totp?.secret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(saved.totp?.digits, 8)
        XCTAssertEqual(saved.totp?.period, 60)
        XCTAssertEqual(saved.totp?.issuer, "GitHub")

        // Codes generated from the reloaded seed match the engine directly.
        let reloaded = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore(data: store.loadData()))
        let reloadTOTP = try XCTUnwrap(reloaded.localRecords.first?.totp)
        let at = Date(timeIntervalSince1970: 1111111109)
        XCTAssertEqual(
            TOTPEngine.code(for: reloadTOTP, at: at),
            TOTPEngine.code(for: saved.totp!, at: at)
        )
    }

    func testEditingKeepsSeedWhenTOTPInputLeftEmpty() async throws {
        let store = InMemoryRecordStore()
        let model = makeOfflineModel(store: store)
        model.recordPassword = "secret-1"
        model.recordTOTPInput = "JBSWY3DPEHPK3PXP"
        await model.saveRecord()
        let record = try XCTUnwrap(model.latestSavedRecord)

        model.beginEditing(record)
        XCTAssertEqual(model.recordExistingTOTP?.secret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(model.recordTOTPInput, "", "the stored seed must never be re-displayed")
        await model.saveRecord()

        XCTAssertEqual(model.latestSavedRecord?.totp?.secret, "JBSWY3DPEHPK3PXP", "empty input keeps the seed")
    }

    func testEditingCanReplaceAndRemoveTOTP() async throws {
        let model = makeOfflineModel()
        model.recordPassword = "secret-1"
        model.recordTOTPInput = "JBSWY3DPEHPK3PXP"
        await model.saveRecord()
        let record = try XCTUnwrap(model.latestSavedRecord)

        model.beginEditing(record)
        model.recordTOTPInput = "KRSXG5CTMVRXEZLU"
        await model.saveRecord()
        XCTAssertEqual(model.latestSavedRecord?.totp?.secret, "KRSXG5CTMVRXEZLU")

        model.beginEditing(try XCTUnwrap(model.latestSavedRecord))
        model.recordTOTPRemoveRequested = true
        await model.saveRecord()
        XCTAssertNil(model.latestSavedRecord?.totp, "remove flag clears the seed")
    }

    func testInvalidTOTPInputBlocksSave() async {
        let model = makeOfflineModel()
        model.recordTitle = "Bad Seed"
        model.recordPassword = "secret-1"
        model.recordTOTPInput = "not-base32!!"
        await model.saveRecord()

        XCTAssertNil(model.latestSavedRecord, "invalid seed must block the save")
        XCTAssertEqual(model.statusMessage, "TOTP seed must be a base32 secret or otpauth:// URI")
    }

    func testPastedOTPAuthURIIsCapturedAsTOTPNotFields() async throws {
        let model = makeOfflineModel()
        model.pastedText = "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 otpauth://totp/GitHub:ops-bot@example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"
        await model.saveFromPastedText()

        let record = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(record.totp?.secret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(record.primarySecret, "GhOpsBot@2026")
        for field in record.fields {
            XCTAssertFalse(field.value.contains("otpauth://"), "URI must not leak into fields")
        }
        XCTAssertFalse(record.notes.contains("otpauth://"))
    }

    func testURIOnlyPasteCreatesAuthenticatorEntry() async throws {
        let model = makeOfflineModel()
        model.pastedText = "otpauth://totp/Vault%20Corp:admin?secret=JBSWY3DPEHPK3PXP&issuer=Vault%20Corp"
        XCTAssertTrue(model.pastedSecretPreview?.hasTOTP == true, "preview must flag the detected URI")
        await model.saveFromPastedText()

        let record = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(record.templateType, "account")
        XCTAssertEqual(record.totp?.secret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(record.totp?.issuer, "Vault Corp")
        XCTAssertNil(record.primarySecret)
    }

    func testPreviewFlagsDetectedTOTP() {
        let model = makeOfflineModel()
        model.pastedText = "service=GitHub username=ops@example.com password=x otpauth://totp/GitHub?secret=JBSWY3DPEHPK3PXP"
        XCTAssertTrue(model.pastedSecretPreview?.hasTOTP == true)
        XCTAssertTrue(model.pastedSecretPreview?.tags.contains("两步验证") == true)
    }

    // MARK: - Permission matrix

    func testEffectivePermissionsMapsLegacyAIReadableFlag() {
        var legacy = VaultRecord(
            id: "legacy", itemType: "secret", templateType: nil, name: "Legacy",
            subtitle: nil, notes: "", tags: [], fields: [],
            passwordHash: "h", passwordFingerprint: "f", primarySecret: "s", matchReason: nil
        )
        legacy.aiReadable = true
        XCTAssertEqual(legacy.effectivePermissions.aiAccess, .metadataAndTools)

        legacy.aiReadable = nil
        XCTAssertEqual(legacy.effectivePermissions.aiAccess, .none, "nil legacy flag denies by default")
    }

    func testSavedPermissionsPersistThroughKeychainRoundTrip() async throws {
        let store = InMemoryRecordStore()
        let model = makeOfflineModel(store: store)
        model.recordTitle = "Locked Redis"
        model.recordPassword = "redis-secret"
        model.recordPermissions = RecordPermissions(
            readOnly: true, hideSecret: true, requireReauth: true, aiAccess: .metadata
        )
        await model.saveRecord()

        let saved = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(saved.effectivePermissions.readOnly, true)
        XCTAssertEqual(saved.effectivePermissions.hideSecret, true)
        XCTAssertEqual(saved.effectivePermissions.requireReauth, true)
        XCTAssertEqual(saved.effectivePermissions.aiAccess, .metadata)
        XCTAssertEqual(saved.aiReadable, true, "legacy boolean mirrors any non-none level")

        let reloaded = SecretBoxAppModel(defaults: defaults, recordStore: InMemoryRecordStore(data: store.loadData()))
        XCTAssertEqual(reloaded.localRecords.first?.effectivePermissions.aiAccess, .metadata)
    }

    func testReadOnlyRecordBlocksEditSaveAndDeleteUntilUnlocked() async throws {
        let model = makeOfflineModel()
        model.recordPassword = "secret-1"
        await model.saveRecord()
        let record = try XCTUnwrap(model.latestSavedRecord)

        model.setAIAccess(id: record.id, level: .metadataAndTools)
        model.beginEditing(record)
        model.recordPermissions.readOnly = true
        await model.saveRecord()
        let locked = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertTrue(locked.effectivePermissions.readOnly)

        // Blocked: save while still read-only, and delete.
        model.beginEditing(locked)
        model.recordNote = "attempted edit"
        await model.saveRecord()
        XCTAssertEqual(model.statusMessage, "Record is locked read-only")
        XCTAssertNotEqual(model.latestSavedRecord?.notes, "attempted edit")

        model.deleteRecord(id: locked.id)
        XCTAssertEqual(model.statusMessage, "Record is locked read-only")
        XCTAssertEqual(model.localRecords.count, 1)

        // The deliberate unlock path: flipping the toggle off allows the save.
        model.beginEditing(locked)
        model.recordPermissions.readOnly = false
        await model.saveRecord()
        XCTAssertFalse(model.latestSavedRecord?.effectivePermissions.readOnly ?? true)
    }

    func testRequireReauthGatesSecretUseThroughInjectableGate() async throws {
        let denied = StubReauthGate(nextResult: false)
        let model = makeOfflineModel(reauthGate: denied)
        model.recordPassword = "secret-1"
        model.recordPermissions.requireReauth = true
        await model.saveRecord()
        let record = try XCTUnwrap(model.latestSavedRecord)

        // Denied gate blocks the secret use.
        let granted = await model.requestSecretUse(for: record, action: "copy the password")
        XCTAssertFalse(granted)
        XCTAssertEqual(denied.challengeCount, 1)
        XCTAssertEqual(model.statusMessage, "Authentication required to copy the password")

        // Records without the flag never consult the gate.
        let idleGate = StubReauthGate(nextResult: false)
        let plainModel = makeOfflineModel(reauthGate: idleGate)
        var plain = record
        plain.permissions?.requireReauth = false
        let plainGranted = await plainModel.requestSecretUse(for: plain, action: "copy")
        XCTAssertTrue(plainGranted)
        XCTAssertEqual(idleGate.challengeCount, 0)

        // Allowed gate passes through.
        let allowedGate = StubReauthGate(nextResult: true)
        let gatedModel = makeOfflineModel(reauthGate: allowedGate)
        let gatedGranted = await gatedModel.requestSecretUse(for: record, action: "copy")
        XCTAssertTrue(gatedGranted)
        XCTAssertEqual(allowedGate.challengeCount, 1)
    }

    func testSetAIAccessLevelsPersistAndMirrorLegacyFlag() async throws {
        let model = makeOfflineModel()
        model.pastedText = "service=GitHub username=ops@example.com password=GhOpsBot@2026"
        await model.saveFromPastedText()
        let record = try XCTUnwrap(model.latestSavedRecord)
        XCTAssertEqual(record.effectivePermissions.aiAccess, .none)

        model.setAIAccess(id: record.id, level: .metadata)
        var updated = try XCTUnwrap(model.localRecords.first)
        XCTAssertEqual(updated.permissions?.aiAccess, .metadata)
        XCTAssertEqual(updated.aiReadable, true)

        model.setAIAccess(id: record.id, level: .none)
        updated = try XCTUnwrap(model.localRecords.first)
        XCTAssertEqual(updated.permissions?.aiAccess, AIAccessLevel.none)
        XCTAssertEqual(updated.aiReadable, false, "disable persists an explicit false")
    }

    func testCopyTOTPCodePlacesCodeOnClipboard() {
        let model = makeOfflineModel()
        model.copyTOTPCode("123456")
        XCTAssertEqual(PlatformClipboard.string, "123456")
        XCTAssertEqual(model.statusMessage, "Verification code copied")
    }
}
