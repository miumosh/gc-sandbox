# 追加の監視（Certificate Manager／Backup and DR／Oracle Autonomous AI Database／Compute Engine のイベント）

[monitoring-result.md](monitoring-result.md) の M1〜M5 に加えて、構成に含まれる（または今後含まれる）サービスで必要になる監視を整理したもの。

> 注意: この資料は **ドキュメントレベルの整理** で、今回の検証環境（HTTP の内部 ALB、VM 2 台、Cloud Scheduler）では動かしていない。ログ名・指標名・項目名は公式ドキュメント（末尾の「参考」）に基づくが、導入時に Logs Explorer／Metrics Explorer／Datadog の Log Explorer で実データを確認してから有効化する。「要確認」と書いたものは、公式ドキュメントで値を確認しきれていない項目。

- 書き方は [monitoring-result.md](monitoring-result.md)・[monitor-result-datadog.md](monitor-result-datadog.md) にそろえる（GCP 側の条件は Cloud Logging の検索クエリ、Datadog 側は `@` 付きの属性）
- ログ監視は、M1〜M5 と同じく Log Router シンク → Pub/Sub → Dataflow → Datadog Logs で取り込む前提。シンクのフィルタに、この資料のログを追加する必要がある（6 章）
- 指標監視は、Datadog GCP インテグレーションで取り込む前提（Datadog の指標名は `gcp.<サービス>.<指標>`）

---

## 0. 一覧

| ID | 対象 | 監視 | 検知したい事象 | Datadog のモニター種別 | 重要度 |
|---|---|---|---|---|---|
| CM1 | Certificate Manager | 証明書の期限切れ間近（ログ） | 証明書の期限が近い。Google マネージド証明書なら **自動更新の失敗** を意味する | Log Monitor | 警告 |
| CM2 | Certificate Manager | 証明書の期限切れ（ログ） | 証明書が期限切れになった | Log Monitor | 危険 |
| CM3 | Certificate Manager | 証明書の残り日数（指標） | ログが届かない場合の保険として、残り日数で見る | Metric Monitor | 警告／危険 |
| CM4 | Certificate Manager | 証明書・証明書マップの変更（監査ログ） | 証明書の削除・置き換えなど、意図しない設定変更 | Log Monitor | 情報 |
| BD1 | Backup and DR | 定期バックアップの失敗 | スケジュールされたバックアップが失敗した | Log Monitor | 危険 |
| BD2 | Backup and DR | 定期バックアップのスキップ | バックアップが実行されなかった（前回のジョブが実行中など） | Log Monitor | 警告 |
| BD3 | Backup and DR | オンデマンドバックアップ・リストアの失敗 | 手動のバックアップや、リストアが失敗した | Log Monitor | 危険 |
| BD4 | Backup and DR | バックアッププランの関連付け（適用）の失敗 | VM へのバックアッププランの適用・更新が失敗した | Log Monitor | 警告 |
| BD5 | Backup and DR | 成功したバックアップが無い（途絶） | 一定期間、成功のログが 1 件も無い（ジョブ自体が動いていない） | Log Monitor（No Data／件数） | 危険 |
| BD6 | Backup and DR | バックアップボールト・プラン・バックアップの削除（監査ログ） | 保護の解除、バックアップの削除 | Log Monitor | 警告 |
| ADB1 | Oracle Autonomous AI Database | 死活 | DB が接続を受け付けない | Metric Monitor | 危険 |
| ADB2〜ADB6 | Oracle Autonomous AI Database | リソース | CPU・ストレージ・セッションの逼迫 | Metric Monitor | 警告／危険 |
| ADB7〜ADB10 | Oracle Autonomous AI Database | 高負荷 | 待ち・キューイング・ブロッキング・応答の遅延 | Metric Monitor | 警告 |
| ADB11〜ADB15 | Oracle Autonomous AI Database | エラー | 接続・ログオンの失敗、DR の遅延、操作の失敗、DB 内部のエラー | Metric／Log Monitor | 警告／危険 |
| GCE1 | Compute Engine | ホスト障害（`hostError`） | Google 側のホスト障害で VM が落ちた | Log Monitor | 危険 |
| GCE2 | Compute Engine | ゲスト OS からのシャットダウン（`guestTerminate`） | OS 内の shutdown・カーネルパニックなどで VM が止まった | Log Monitor | 警告 |
| GCE3 | Compute Engine | ホストメンテナンスでの停止（`terminateOnHostMaintenance`） | メンテナンスポリシーが TERMINATE の VM が停止した | Log Monitor | 警告 |
| GCE4 | Compute Engine | 自動再起動（`automaticRestart`） | GCE1・GCE3 の後に VM が自動で起動した（回復の確認） | Log Monitor | 情報 |
| GCE5 | Compute Engine | ライブマイグレーション（`migrateOnHostMaintenance`） | ホストメンテナンスで VM が移動した（停止はしない） | Log Monitor | 情報 |
| GCE6 | Compute Engine | プリエンプト（`preempted`） | Spot VM が回収された（Spot VM を使う場合だけ） | Log Monitor | 警告 |
| GCE7 | Compute Engine | 計画外の構成変更（監査ログ） | VM の削除・作成・リセット・マシンタイプ変更など | Log Monitor | 警告／情報 |

---

## 1. Certificate Manager

### 1.1 前提

| 項目 | 内容 |
|---|---|
| 想定する使い方 | 内部 ALB（または外部 ALB）を HTTPS にし、証明書を Certificate Manager で管理する |
| 証明書の種類 | Google マネージド証明書（自動更新。内部 ALB では DNS 認証が必要）、またはセルフマネージド証明書（自分でアップロード・更新） |
| ログ | `certificatemanager.googleapis.com/certificates_expiry`（期限切れ・期限間近を記録。常に有効で設定不要）<br>resource.type: `certificatemanager.googleapis.com/Project`<br>`jsonPayload.state`: `CLOSE_TO_EXPIRY`／`EXPIRED` |
| ログが出るタイミング | Google マネージド: **期限の 5〜10 日前から毎日** `CLOSE_TO_EXPIRY`<br>セルフマネージド: **期限の 10 日前から毎日** `CLOSE_TO_EXPIRY` |
| 指標 | `certificatemanager.googleapis.com/project/v2/certificate_expiration`（期限までの残り秒数の分布。有効期間 72 時間超の証明書が対象）<br>`certificatemanager.googleapis.com/project/v2/active_certificates`（使用中の証明書数） |

- **Google マネージド証明書で `CLOSE_TO_EXPIRY` が出た＝自動更新がうまくいっていない**。通常は期限よりかなり前に自動更新されるため、期限 5〜10 日前まで古い証明書が残っていること自体が異常（DNS 認証の CNAME の削除、ALB との紐付けの外れなど）
- セルフマネージド証明書は自動更新されないので、CLOSE_TO_EXPIRY の 10 日前では遅い。CM3（指標）で 30 日前から警告する

### 1.2 監視の詳細

| ID | 監視対象 | エラー判定文字列（GCP） | Datadog の条件 | 評価・閾値 | 解説 |
|---|---|---|---|---|---|
| CM1 | 期限切れ間近のログ | `logName="projects/<PROJECT_ID>/logs/certificatemanager.googleapis.com%2Fcertificates_expiry" jsonPayload.state="CLOSE_TO_EXPIRY"` | `@resource.type:certificatemanager.googleapis.com/Project @jsonPayload.state:CLOSE_TO_EXPIRY` | 直近 1 日で ≧ 1 件 → 警告。証明書別（証明書名の項目、要確認）にグループ化 | 毎日出るので、`renotify_interval` を 1 日にして対応されるまで通知し続ける。Google マネージドなら更新失敗の調査（`gcloud certificate-manager certificates describe` の `managed.state`・`provisioningIssue`・`authorizationAttemptInfo`） |
| CM2 | 期限切れのログ | `logName="projects/<PROJECT_ID>/logs/certificatemanager.googleapis.com%2Fcertificates_expiry" jsonPayload.state="EXPIRED"` | `@resource.type:certificatemanager.googleapis.com/Project @jsonPayload.state:EXPIRED` | ≧ 1 件 → 危険 | ALB がクライアントに期限切れの証明書を出している。クライアントは TLS エラーになる（M1 の 5xx には出ない。ALB まで HTTP のリクエストが届かないため） |
| CM3 | 残り日数の指標 | `certificatemanager.googleapis.com/project/v2/certificate_expiration` | `gcp.certificatemanager.project.v2.certificate_expiration`（Datadog での名前と、分布の扱いは要確認） | 最小値（分布の下限）が 30 日（2,592,000 秒）以下 → 警告、7 日（604,800 秒）以下 → 危険 | プロジェクト全体の分布なので、どの証明書かは分からない（ラベル無し）。通知が来たら `gcloud certificate-manager certificates list` で特定する。ログ（CM1・CM2）の保険と、セルフマネージド証明書の早めの警告に使う |
| CM4 | 証明書・証明書マップの変更 | `logName="projects/<PROJECT_ID>/logs/cloudaudit.googleapis.com%2Factivity" protoPayload.serviceName="certificatemanager.googleapis.com" protoPayload.methodName=~"(Delete\|Update)(Certificate\|CertificateMap\|CertificateMapEntry\|DnsAuthorization)$"` | `@protoPayload.serviceName:certificatemanager.googleapis.com @protoPayload.methodName:(*DeleteCertificate* OR *UpdateCertificate* OR *DeleteDnsAuthorization*)` | ≧ 1 件 → 情報（通知のみ） | 意図しない削除・置き換えの検知と、変更履歴の確認用。メソッド名の正確な形（`google.cloud.certificatemanager.v1.CertificateManager.DeleteCertificate` など）は要確認 |

### 1.3 補足

| 項目 | 内容 |
|---|---|
| 外形監視での確認 | 外部に公開する ALB なら、Datadog Synthetics の SSL テスト（証明書の残り日数で発報）でもよい。内部 ALB は Synthetics のプライベートロケーション（VPC 内にコンテナを置く）が必要 |
| GCP の Uptime Check | 公開エンドポイントなら、HTTPS の Uptime Check の `monitoring.googleapis.com/uptime_check/time_until_ssl_cert_expires` で残り日数を監視できる |
| メンテナンス中 | 抑止しない（VM の停止とは無関係） |

---

## 2. Backup and DR

### 2.1 前提

| 項目 | 内容 |
|---|---|
| 想定する使い方 | VM（`vas-web-*`）をバックアッププランでバックアップボールトに保存する（ボールト方式） |
| ジョブのログ（ボールト方式） | `backupdr.googleapis.com/bdr_backup_plan_jobs`（バックアッププランのジョブ: 定期・オンデマンドのバックアップ、リストア）<br>`backupdr.googleapis.com/bdr_backup_plan_association_jobs`（管理用プロジェクト側の、プランの関連付け）<br>`backupdr.googleapis.com/bdr_backup_plan_association_source_jobs`（ワークロード側プロジェクトの、プランの関連付け）<br>resource.type: `backupdr.googleapis.com/BackupDRProject` |
| 主な項目 | `jsonPayload.jobCategory`: `SCHEDULED_BACKUP`／`ON_DEMAND_BACKUP`／`RESTORE`／`UPDATE`<br>`jsonPayload.jobStatus`: `SUCCESSFUL`／`FAILED`／`SKIPPED`／`RUNNING` |
| バックアップ／リカバリアプライアンス方式の場合 | ログが別になる: `backupdr.googleapis.com/gcb_backup_recovery_jobs`（resource.type `backupdr.googleapis.com/ManagementConsole`、`jsonPayload.job_status` が `Failed` など、項目名がスネークケース）と、`backupdr.googleapis.com/backup_recovery_appliance_events`（アプライアンスのイベント） |

- **ログの重要度（severity）では判定しない**。失敗時の severity が公式ドキュメントに書かれていないため、`jobStatus` で判定する（M1・M5 で severity が当てにならなかったのと同じ考え方）
- ドキュメントによってログ名の表記が揺れている（`bdr_backup_restore_jobs` という例もある）。導入時に Logs Explorer で実際のログ名を確認する

### 2.2 監視の詳細（ボールト方式）

| ID | 監視対象 | エラー判定文字列（GCP） | Datadog の条件 | 評価・閾値 | 解説 |
|---|---|---|---|---|---|
| BD1 | 定期バックアップの失敗 | `logName="projects/<PROJECT_ID>/logs/backupdr.googleapis.com%2Fbdr_backup_plan_jobs" jsonPayload.jobCategory="SCHEDULED_BACKUP" jsonPayload.jobStatus="FAILED"` | `@resource.type:backupdr.googleapis.com/BackupDRProject @jsonPayload.jobCategory:SCHEDULED_BACKUP @jsonPayload.jobStatus:FAILED` | 直近 5 分で ≧ 1 件 → 危険 | 公式ドキュメントの例と同じ条件。バックアップ対象（VM）別にグループ化する場合は、対象リソース名の項目を確認して `.by()` に入れる（要確認） |
| BD2 | 定期バックアップのスキップ | 上と同じで `jsonPayload.jobStatus="SKIPPED"` | `... @jsonPayload.jobCategory:SCHEDULED_BACKUP @jsonPayload.jobStatus:SKIPPED` | ≧ 1 件 → 警告 | 前回のバックアップが終わっていない、VM の状態などで実行されなかった。続く場合はスケジュールや保存期間を見直す |
| BD3 | オンデマンドバックアップ・リストアの失敗 | `logName=".../backupdr.googleapis.com%2Fbdr_backup_plan_jobs" jsonPayload.jobCategory=("ON_DEMAND_BACKUP" OR "RESTORE") jsonPayload.jobStatus="FAILED"` | `... @jsonPayload.jobCategory:(ON_DEMAND_BACKUP OR RESTORE) @jsonPayload.jobStatus:FAILED` | ≧ 1 件 → 危険 | 人が実行したジョブなので、通知先は実行者のチームでもよい。リストアの失敗は障害対応中に起きるので、見落とさないよう危険にする |
| BD4 | プランの関連付けの失敗 | `logName=~"projects/<PROJECT_ID>/logs/backupdr.googleapis.com%2Fbdr_backup_plan_association_(source_)?jobs" jsonPayload.jobStatus="FAILED"` | `@resource.type:backupdr.googleapis.com/BackupDRProject @jsonPayload.jobCategory:UPDATE @jsonPayload.jobStatus:FAILED` | ≧ 1 件 → 警告 | VM にバックアッププランを適用・変更する処理の失敗。失敗すると以降のバックアップが取られない |
| BD5 | 成功したバックアップが無い | `logName=".../backupdr.googleapis.com%2Fbdr_backup_plan_jobs" jsonPayload.jobCategory="SCHEDULED_BACKUP" jsonPayload.jobStatus="SUCCESSFUL"` | `... @jsonPayload.jobCategory:SCHEDULED_BACKUP @jsonPayload.jobStatus:SUCCESSFUL` | バックアップの間隔＋余裕（例: 1 日 1 回なら直近 26 時間）で **≦ 0 件** → 危険 | BD1〜BD4 は「失敗のログが出た」ときしか鳴らない。プランの削除・関連付けの解除・ジョブが起動しないなど、ログ自体が出ない場合はこれで拾う（M3・M4 で「ジョブが実行されない」が検知できなかったのと同じ問題への対策）。VM 別にグループ化する |
| BD6 | ボールト・プラン・バックアップの削除 | `logName="projects/<PROJECT_ID>/logs/cloudaudit.googleapis.com%2Factivity" protoPayload.serviceName="backupdr.googleapis.com" protoPayload.methodName=~"Delete(BackupVault\|BackupPlan\|BackupPlanAssociation\|Backup)$"` | `@protoPayload.serviceName:backupdr.googleapis.com @protoPayload.methodName:*Delete*` | ≧ 1 件 → 警告 | 保護の解除や、バックアップの削除（ランサムウェア対策の観点）。メソッド名の正確な形は要確認 |

### 2.3 補足

| 項目 | 内容 |
|---|---|
| メンテナンス中 | 抑止しない。ただし月次メンテナンスで VM を止めている時間とバックアップの時間が重なると、BD2（スキップ）や BD1 が出る可能性がある。**バックアップの時間帯をメンテナンスの時間帯からずらす** |
| 通知の間隔 | 1 日 1 回のバックアップなら、失敗は 1 日 1 件。`renotify_interval` は設定しない（翌日の失敗で再度鳴る） |
| レポート | 失敗の傾向（日・週・月の失敗数）は、Backup and DR のレポートか、ログベース指標でグラフにする |

---

## 3. Oracle Autonomous AI Database（Oracle Database@Google Cloud）

### 3.1 前提

| 項目 | 内容 |
|---|---|
| 指標の取り込み | GCP の Cloud Monitoring に「Autonomous Database」の指標が出る。Datadog は GCP インテグレーション（Oracle AI Database@Google Cloud）で `gcp.oracledatabase.autonomousdatabase.*` として取り込む |
| ログ | 監査ログ（`oracledatabase.googleapis.com`。誰がどの操作をしたか）と、リソースログ（Autonomous AI Database サービスのイベント）が Cloud Logging に出る。リソースログのログ名は要確認（Logs Explorer で「Autonomous AI Database」のリソースを選んで確認） |
| Datadog のイベント・サービスチェック | このインテグレーションには無い。死活は指標（`database_availability`）で見る |
| 取れないもの | **メモリの指標は無い**（Autonomous は CPU（ECPU）とストレージで管理される）。**DB 内部のエラー（ORA- エラー、アラートログ）は GCP 側に出ない** → ADB15 で別途対応 |
| 指標の名前 | 以下は Datadog での名前（`gcp.oracledatabase.autonomousdatabase.` を省略）。GCP 側の指標の型は Metrics Explorer で確認する。DB を識別するタグ名も取り込み後に確認する |

### 3.2 死活・リソース

| ID | 分類 | 監視対象メトリクス | 評価期間 | アラート判定条件 | 閾値（危険） | 閾値（警告） | 解説 |
|---|---|---|---|---|---|---|---|
| ADB1 | 死活 | `database_availability`（1 分ごとに、接続を受け付けたら 1、受け付けなければ 0） | 直近 5 分の平均 | 閾値以下になったら（メトリクス <= 閾値） | **0**（5 分間ずっと使えない） | **0.6**（5 分のうち 2 分以上使えない） | M2 と同じ考え方。DB ごと消えた・取り込みが止まった場合に備えて `default_zero()` を付けるか、`notify_no_data`（10 分程度）を併用する。計画メンテナンスの時間は Downtime |
| ADB2 | リソース | `cpu_utilization`（使える CPU に対する使用率、%） | 直近 15 分の平均 | 閾値以上になったら（メトリクス >= 閾値） | **90** | **80** | 自動スケーリングが有効なら、上限まで使い切っているかを見る。短時間の山で鳴らないよう 15 分の平均にする |
| ADB3 | リソース | `storage_utilization`（予約した最大ストレージに対する使用率、%） | 直近 1 時間の最大 | 閾値以上になったら（メトリクス >= 閾値） | **90** | **80** | 一杯になると書き込みが失敗する。増え方はゆっくりなので評価期間は長めでよい |
| ADB4 | リソース | `storage_used`（使用量）／`storage_max`（上限） | – | – | – | – | ADB3 の補助。ダッシュボードで増え方を見て、いつ一杯になるかを予測する（Datadog の forecast モニターも使える） |
| ADB5 | リソース | `session_utilization`（セッションの使用率の最大、%） | 直近 5 分の最大 | 閾値以上になったら（メトリクス >= 閾値） | **90** | **80** | 上限に達すると新しい接続が拒否される。アプリ側のコネクションプールの設定ミス・リークでも上がる |
| ADB6 | リソース | `sessions`（セッション数） | – | – | – | – | ADB5 の補助。平常時の値を把握し、急増していないかをダッシュボードで見る |

### 3.3 高負荷

| ID | 監視対象メトリクス | 評価期間 | アラート判定条件 | 閾値（危険） | 閾値（警告） | 解説 |
|---|---|---|---|---|---|---|
| ADB7 | `average_active_sessions`（実行中または待ちのセッション数の平均） | 直近 15 分の平均 | 閾値以上になったら（メトリクス >= 閾値） | – | **割り当てた CPU 数（ECPU 数を元に換算）を超える値**（要調整） | CPU 数より多いと、処理待ちが発生している。CPU 使用率（ADB2）が低いのに高い場合は、I/O やロックで待っている |
| ADB8 | `queued_statements`（実行待ちの SQL 数） | 直近 10 分の平均 | 閾値より高く／大きくなったら（メトリクス > 閾値） | – | **0**（10 分間ずっと待ちがある） | 同時実行数の上限（サービス名ごとの制限）に達している。続くとアプリの応答が遅くなる |
| ADB9 | `blocking_sessions`（他のセッションをブロックしているセッション数） | 直近 5 分の最小 | 閾値より高く／大きくなったら（メトリクス > 閾値） | – | **0**（5 分間ずっとブロックが続く） | ロックの待ちが解けない。長時間のトランザクションやデッドロックに近い状態 |
| ADB10 | `query_latency`（簡単な問い合わせの応答時間、ms）／`connection_latency`（同じリージョンの VM からの接続時間、ms） | 直近 15 分の平均 | 閾値以上になったら（メトリクス >= 閾値） | 平常時の 5 倍（要調整） | 平常時の 3 倍（要調整） | ユーザーから見た遅さに近い指標。固定値ではなく平常時の値を測ってから決める（Datadog の anomaly モニターも使える） |

### 3.4 エラー

| ID | 監視対象 | 条件 | 閾値 | 解説 |
|---|---|---|---|---|
| ADB11 | `failed_connections`（接続の失敗数）、`connections_dropped_by_server`（サーバー側から切った接続数） | 直近 5 分の合計 | ≧ 平常時の値を見て決める（要調整）→ 警告 | ネットワーク・リスナー・上限（ADB5）の問題。アプリ側のエラーと時刻を合わせて見る |
| ADB12 | `failed_logons`（ユーザー名・パスワードの誤りによるログオン失敗数） | 直近 5 分の合計 | ≧ 10 → 警告（要調整） | パスワードの変更漏れ（アプリの接続設定が古い）や、総当たりの攻撃。セキュリティの観点でも見る |
| ADB13 | `peer_lag`（DR 先（Autonomous Data Guard）の遅れ、秒） | 直近 15 分の平均 | ≧ 300 秒 → 警告、≧ 900 秒 → 危険（RPO に合わせて決める） | DR を構成している場合だけ。遅れが大きいと、切り替え時に失うデータが増える |
| ADB14 | 監査ログ・リソースログの失敗 | GCP: `protoPayload.serviceName="oracledatabase.googleapis.com" severity>=ERROR`（監査ログ）と、リソースログの `severity>=ERROR`<br>Datadog: `@protoPayload.serviceName:oracledatabase.googleapis.com status:(error OR critical OR alert OR emergency)` | ≧ 1 件 → 警告 | 起動・停止・スケーリング・バックアップなど、DB に対する操作やサービス側の処理の失敗。リソースログのログ名と、どのイベントが ERROR になるかは要確認 |
| ADB15 | DB 内部のエラー（ORA- エラー、アラートログ） | GCP・Datadog GCP インテグレーションでは取れない | – | 必要なら次のどれかを追加する（いずれも要確認）<br>・OCI 側の Events／Notifications、OCI Monitoring のアラーム<br>・OCI Database Management（アラートログの監視）<br>・Datadog Agent の Oracle インテグレーション・Database Monitoring（Agent を置いた VM から ADB に接続して取得） |

### 3.5 補足

| 項目 | 内容 |
|---|---|
| 計画メンテナンス | Autonomous はOracle 側で定期メンテナンスがある。その時間は ADB1・ADB10・ADB11 を Downtime にする（メンテナンスの予定は OCI 側の通知で確認） |
| VM の月次メンテナンス | VM が止まっている間は接続が減るだけなので、抑止しない（ADB の監視は VM の停止の影響を受けない） |
| 閾値 | すべて一般的な目安。導入後 1〜2 週間の平常時の値を見て調整する |

---

## 4. Compute Engine のイベント（ライフサイクル）

### 4.1 前提

| 項目 | 内容 |
|---|---|
| ログ | システムイベント監査ログ `cloudaudit.googleapis.com/system_event`（Google 側が起こしたイベント。`principalEmail` は `system@google.com`。**常に有効で無効にできない**）<br>管理アクティビティ監査ログ `cloudaudit.googleapis.com/activity`（人・SA・サービスエージェントが起こした操作） |
| resource.type | `gce_instance` |
| 既存の監視との関係 | M4 は `activity` の起動・停止の **失敗** だけを見ている。ここでは、Google 側のイベントと、成功した計画外の操作を見る |
| 重要度（severity） | イベントの種類で判定し、severity は使わない（severity は種類によって異なり、要確認） |

- 検証では、Scheduler による停止・起動の間に system_event のログは出なかった（保存したログ `audit-system-event.json` は 0 件）。Scheduler の操作は `activity` 側に出る

### 4.2 監視の詳細

| ID | イベント（methodName） | ログ | 意味 | 重要度 | 解説・対応 |
|---|---|---|---|---|---|
| GCE1 | `compute.instances.hostError` | system_event | ホストのハードウェア・ソフトウェアの障害で VM が落ちた | 危険 | 自動再起動が有効なら、約 3 分以内に GCE4 が続く。GCE4 が来なければ VM は止まったまま（M2 も鳴る）。頻発する場合は Google のサポートに問い合わせる |
| GCE2 | `compute.instances.guestTerminate` | system_event | ゲスト OS がシャットダウンを始めた（`shutdown` コマンド、カーネルパニック後の停止など） | 警告 | 人が OS 内で止めたのか、障害で止まったのかを、シリアルコンソールのログで確認する。監査ログ（activity）の stop は出ないので M4 では拾えない |
| GCE3 | `compute.instances.terminateOnHostMaintenance` | system_event | ホストメンテナンスで VM が停止した（メンテナンスポリシーが TERMINATE の場合） | 警告 | 既定（MIGRATE）なら出ない。TERMINATE にしている場合は、自動再起動（GCE4）で戻ることを確認する |
| GCE4 | `compute.instances.automaticRestart` | system_event | GCE1・GCE3 の後、自動再起動で VM が起動した | 情報 | 回復の確認用。GCE1・GCE3 の通知とセットで見る |
| GCE5 | `compute.instances.migrateOnHostMaintenance` | system_event | ホストメンテナンスで VM がライブマイグレーションされた（停止しない） | 情報 | 通常は影響なし。移行中に一瞬性能が落ちることがあるので、遅延などの調査用に記録だけ残す（通知しないか、情報のみ）。ログに出るメソッド名は要確認 |
| GCE6 | `compute.instances.preempted` | system_event | Spot VM・プリエンプティブル VM が回収された | 警告 | Spot VM を使う場合だけ。自動削除の設定によっては、`system@google.com` による `compute.instances.delete` だけが出ることがある |
| GCE7 | `compute.instances.delete`、`compute.instances.insert`、`compute.instances.reset`、`compute.instances.setMachineType` など | activity | VM の削除・作成・リセット・マシンタイプ変更 | 削除は警告、それ以外は情報 | 計画外の変更を拾う。Scheduler の start／stop（`vas-scheduler@...`）や、Terraform・CI の SA による操作は除外する |
| （参考） | `compute.instances.repair.recreateInstance` | system_event | マネージドインスタンスグループ（MIG）が VM を作り直した | 情報 | MIG の自動修復を使う場合だけ。今の構成（非マネージドのインスタンスグループ）では出ない |

### 4.3 エラー判定文字列

| ID | エラー判定文字列（GCP） | Datadog の条件 | 評価・閾値 |
|---|---|---|---|
| GCE1〜GCE6 | `logName="projects/<PROJECT_ID>/logs/cloudaudit.googleapis.com%2Fsystem_event" resource.type="gce_instance" protoPayload.methodName=~"compute\.instances\.(hostError\|guestTerminate\|terminateOnHostMaintenance\|automaticRestart\|migrateOnHostMaintenance\|preempted)$" protoPayload.resourceName=~"/instances/vas-web-[0-9]+$"` | `@resource.type:gce_instance @protoPayload.methodName:(*compute.instances.hostError OR *compute.instances.guestTerminate OR *compute.instances.terminateOnHostMaintenance OR *compute.instances.preempted) @protoPayload.resourceName:*vas-web-*` | 直近 5 分で ≧ 1 件。VM（`@protoPayload.resourceName`）別にグループ化。重要度ごとにモニターを分ける（GCE1 は危険、GCE2・3・6 は警告、GCE4・5 は情報）|
| GCE7 | `logName="projects/<PROJECT_ID>/logs/cloudaudit.googleapis.com%2Factivity" resource.type="gce_instance" protoPayload.methodName=~"compute\.instances\.(delete\|insert\|reset\|setMachineType)$" protoPayload.resourceName=~"/instances/vas-web-[0-9]+$" NOT protoPayload.authenticationInfo.principalEmail=("vas-scheduler@<PROJECT_ID>.iam.gserviceaccount.com" OR "<Terraform・CI の SA>")` | `@resource.type:gce_instance @protoPayload.methodName:(*compute.instances.delete OR *compute.instances.insert OR *compute.instances.reset OR *compute.instances.setMachineType) @protoPayload.resourceName:*vas-web-* -@protoPayload.authenticationInfo.principalEmail:(vas-scheduler@* OR <Terraform・CI の SA>)` | 直近 5 分で ≧ 1 件 |

### 4.4 補足

| 項目 | 内容 |
|---|---|
| M2（Uptime）との関係 | GCE1〜GCE3 の後に VM が戻らなければ、M2 も鳴る。GCE は「なぜ止まったか」を数十秒〜数分で知らせ、M2 は「止まったまま」を知らせる役割分担 |
| 月次メンテナンス中 | 抑止しない。Scheduler の停止・起動は activity 側に出るので、GCE1〜GCE6 とは重ならない。GCE7 は Scheduler の SA を除外しているので鳴らない |
| メンテナンスの事前通知 | ホストメンテナンスの予定は、VM のメタデータサーバー（`maintenance-event`）や、VM の `upcomingMaintenance` で確認できる。事前に知りたい場合は別途検討 |
| ログの転送 | `system_event` は、今のシンクのフィルタ（`activity` の start／stop のみ）に含まれていない。6 章のとおり追加する |

---

## 5. 監視の追加で検知できるようになること

| 事象 | 今の M1〜M5 | 追加後 | 追加する監視 |
|---|---|---|---|
| 証明書の自動更新の失敗 | ✕ | ◯（期限の 5〜10 日前） | CM1 |
| 証明書の期限切れ | ✕（TLS エラーは 5xx に出ない） | ◯ | CM2・CM3 |
| バックアップの失敗・スキップ | ✕ | ◯ | BD1〜BD4 |
| バックアップが取られていない（プランの外れなど） | ✕ | ◯ | BD5 |
| DB が使えない | ✕ | ◯ | ADB1 |
| DB のリソース逼迫・高負荷 | ✕ | ◯ | ADB2〜ADB10 |
| DB 内部のエラー（ORA-） | ✕ | △（OCI 側か Datadog Agent が必要） | ADB15 |
| ホスト障害による VM の停止 | ◯（M2、約 10 分。原因は分からない） | ◯（原因が分かる。数分以内） | GCE1・GCE4 |
| OS 内からの VM の停止 | ◯（M2、約 10 分。原因は分からない） | ◯（原因が分かる） | GCE2 |
| 計画外の VM の削除・リセット | △（M2 で停止として拾う） | ◯（誰が操作したかが分かる） | GCE7 |

---

## 6. Datadog へのログ転送（シンクのフィルタに追加するもの）

[monitoring-result.md](monitoring-result.md) の 3.3 のフィルタに、次を OR で追加する。

```
OR
(logName="projects/<PROJECT_ID>/logs/certificatemanager.googleapis.com%2Fcertificates_expiry")
OR
(logName:"logs/backupdr.googleapis.com%2Fbdr_backup_plan")
OR
(logName="projects/<PROJECT_ID>/logs/cloudaudit.googleapis.com%2Fsystem_event"
  AND resource.type="gce_instance")
OR
(logName="projects/<PROJECT_ID>/logs/cloudaudit.googleapis.com%2Factivity"
  AND protoPayload.serviceName=("certificatemanager.googleapis.com" OR "backupdr.googleapis.com" OR "oracledatabase.googleapis.com"))
OR
(logName="projects/<PROJECT_ID>/logs/cloudaudit.googleapis.com%2Factivity"
  AND resource.type="gce_instance"
  AND protoPayload.methodName=~"compute\.instances\.(delete|insert|reset|setMachineType)$")
```

| 追加するログ | 件数の目安 | 理由 |
|---|---|---|
| Certificate Manager の期限ログ | 期限が近いときだけ 1 日 1 件 | CM1・CM2 |
| Backup and DR のジョブログ | バックアップ 1 回あたり数件 | BD1〜BD5（BD5 のため成功ログも送る） |
| system_event | 障害・メンテナンスのときだけ | GCE1〜GCE6 |
| 各サービスの activity | 操作したときだけ | CM4・BD6・ADB14・GCE7 |

- Oracle Autonomous AI Database のリソースログは、ログ名を確認してから追加する（ADB14）
- Backup and DR が別プロジェクト（管理用プロジェクト）にある場合は、そのプロジェクトにもシンクを作る

---

## 参考

- Certificate Manager のログと指標: https://docs.cloud.google.com/certificate-manager/docs/logs-metrics
- Cloud Monitoring の指標一覧（certificatemanager）: https://docs.cloud.google.com/monitoring/api/metrics_gcp_c
- Backup and DR のログベースアラート（ボールト方式）: https://docs.cloud.google.com/backup-disaster-recovery/docs/monitor-reports/configure-alerts-vault
- Backup and DR のジョブログ（アプライアンス方式）: https://docs.cloud.google.com/backup-disaster-recovery/docs/monitor-reports/job-logs
- Oracle Database@Google Cloud の Cloud Monitoring: https://docs.cloud.google.com/oracle/database/docs/monitoring-metrics
- Oracle Database@Google Cloud のリソースログ: https://docs.cloud.google.com/oracle/database/docs/view-resource-logs
- Datadog の Oracle AI Database@Google Cloud インテグレーション（指標一覧）: https://docs.datadoghq.com/integrations/google-cloud-oracledatabase/
- VM のシャットダウン・再起動のトラブルシューティング（ライフサイクルイベント）: https://docs.cloud.google.com/compute/docs/troubleshooting/troubleshooting-reboots
- ホストメンテナンスの概要: https://docs.cloud.google.com/compute/docs/instances/host-maintenance-overview
