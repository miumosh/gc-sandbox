# 必須の監視（内部 ALB／Compute Engine／Cloud Scheduler）

今回の検証（[RESULTS.md](RESULTS.md)／[test-history.md](test-history.md)）で決めた 5 つの監視（M1〜M5）を、[monitor-additional.md](monitor-additional.md) と同じ形式で 1 つにまとめたもの。

> 注意: GCP 側の条件は、検証で動作を確認した条件（A1・A2・A5・S1・S3）をもとにしている。Datadog への取り込みとモニターは、今回の検証では動かしていない（未検証）。導入時は Datadog の Log Explorer で、検索クエリが想定どおりのログに一致するかを確認してから有効化する。

- 書き方は [monitoring-result.md](monitoring-result.md)（GCP 側の条件は Cloud Logging の検索クエリ）、[monitor-result-datadog.md](monitor-result-datadog.md)（Datadog 側は `@` 付きの属性）と同じ。条件・閾値はこの 2 つから写している。モニターの通知メッセージや Terraform の例は monitor-result-datadog.md を見る
- ログ監視は、Log Router シンク → Pub/Sub → Dataflow → Datadog Logs で取り込む前提（7 章）
- 指標監視は、Datadog GCP インテグレーションで取り込む前提（Datadog の指標名は `gcp.<サービス>.<指標>`）
- Datadog の属性名の書き方（`@protoPayload` か `@protopayload` か、前に `data.` が付くか）は、既存の Workflows の監視で動いている書き方に合わせる

---

## 0. 一覧

| ID | 役割 | 対象 | 監視 | 検知したい事象 | Datadog のモニター種別 | 重要度 |
|---|---|---|---|---|---|---|
| M1 | 補助 | Cloud Load Balancing（内部 ALB） | ALB のリクエストログ 5xx 系 | ユーザーにエラーが返った（全台停止、業務 URL のエラー、ALB の異常）。**リクエストが無いと検知できない** | Log Monitor | 危険／警告 |
| M2 | 土台 | Compute Engine | VM の Uptime（指標） | VM の停止（ALB の状態やリクエストの有無に依らない） | Metric Monitor | 危険／警告 |
| M3 | 土台 | Cloud Scheduler | ジョブの実行ログ | Scheduler の起動・停止の失敗（権限不足、API の受付拒否など） | Log Monitor | 危険 |
| M4 | 土台 | Compute Engine | 監査ログ（管理アクティビティ） | 起動・停止の API 呼び出しの失敗、および受付後の処理の失敗 | Log Monitor | 危険 |
| M5 | 土台 | Cloud Load Balancing（内部 ALB） | ヘルスチェックログ（HEALTHY→UNHEALTHY 遷移） | VM は動いているが、アプリが停止・ハングした（リクエストの有無に依らない） | Log Monitor | 危険 |

- VM・アプリの死活は **M2（VM の停止）＋ M5（アプリの停止）** を土台にする。M1 はユーザーへの影響を見る補助
- M3 と M4 は必ずセットで使う（3 章）

---

## 1. Cloud Load Balancing（内部 ALB）

### 1.1 前提

| 項目 | 内容 |
|---|---|
| プロジェクト ID | `miumosh-sb-test01`（検証環境。本番では置き換える） |
| 転送ルール | `vas-fr-http`（VIP `10.10.0.10`、リージョン `asia-northeast1`） |
| バックエンドサービス | `vas-bes`（URL マップ `vas-urlmap`） |
| インスタンスグループ | `vas-ig-web-1`（asia-northeast1-a）、`vas-ig-web-2`（asia-northeast1-b）。1 グループに VM 1 台 |
| ヘルスチェック | `vas-hc`。`/` に 5 秒間隔、2 回連続で失敗すると UNHEALTHY。`log_config.enable = true`（状態が変わったときだけログが出る） |
| リクエストログ（M1） | logName: `projects/miumosh-sb-test01/logs/loadbalancing.googleapis.com%2Frequests`<br>resource.type: `internal_http_lb_rule`<br>バックエンドサービスの `log_config` でサンプリング率 1.0 が前提 |
| ヘルスチェックログ（M5） | logName: `projects/miumosh-sb-test01/logs/compute.googleapis.com%2Fhealthchecks`<br>resource.type: `gce_instance_group` |
| 保存先 | GCP: `_Default` ログバケット（保持 30 日）／Datadog: ログインデックス `main` |

- **どちらのログも、ログの重要度（severity）では判定できない**。リクエストログは 5xx でも `WARNING`（検証時の 5xx 174 件すべて）、ヘルスチェックログは UNHEALTHY への遷移でも `INFO`（保存したログ 17 件すべて）。HTTP ステータスや状態の項目で判定する

### 1.2 監視の詳細

| ID | 監視対象 | エラー判定文字列（GCP） | Datadog の条件 | 評価・閾値 | 解説 |
|---|---|---|---|---|---|
| M1 | ALB が返した 5xx | `logName="projects/miumosh-sb-test01/logs/loadbalancing.googleapis.com%2Frequests" resource.type="internal_http_lb_rule" resource.labels.forwarding_rule_name="vas-fr-http" httpRequest.status>=500 httpRequest.status<600` | `@resource.type:internal_http_lb_rule @resource.labels.forwarding_rule_name:vas-fr-http @httpRequest.status:>=500` | 直近 5 分の件数。≧ 20 件 → 危険、≧ 1 件 → 警告。グループ化なし（全台停止では `backend_name` が空になるため） | ・転送ルール名で絞る（内部 ALB のログにはバックエンドサービス名のラベルが無い）<br>・`proxyStatus` は条件に入れない（5xx 174 件のうち付いていたのは 27 件だけ）<br>・除外: GCP の Uptime Check を併用する場合は、GCP は `NOT httpRequest.userAgent=~"^GoogleStackdriverMonitoring-UptimeChecks"`、Datadog は `-@httpRequest.userAgent:GoogleStackdriverMonitoring*` を追加（全台停止時に重複して数えるため）<br>・閾値の根拠（2 秒ごとのリクエスト）: 全台停止は約 30 件／分、アプリ停止は 4 件、VM 1 台の停止は 1 件。危険の閾値は本番のリクエスト量で見直す<br>・Datadog で `httpRequest.status` が `@http.status_code` に変換されている場合は、そちらで書く |
| M5 | ヘルスチェックの HEALTHY→UNHEALTHY 遷移 | `logName="projects/miumosh-sb-test01/logs/compute.googleapis.com%2Fhealthchecks" resource.type="gce_instance_group" resource.labels.instance_group_name=~"^vas-ig-web-[0-9]+$" jsonPayload.healthCheckProbeResult.healthState="UNHEALTHY" jsonPayload.healthCheckProbeResult.previousHealthState="HEALTHY"` | `@resource.type:gce_instance_group @resource.labels.instance_group_name:vas-ig-web-* @jsonPayload.healthCheckProbeResult.healthState:UNHEALTHY @jsonPayload.healthCheckProbeResult.previousHealthState:HEALTHY` | 直近 5 分の件数。≧ 1 件 → 危険。インスタンスグループ（`@resource.labels.instance_group_name`）別 | ・`previousHealthState="HEALTHY"` が必須。入れないと、起動直後の `UNHEALTHY(UNKNOWN)→UNHEALTHY(TIMEOUT)` で起動のたびに誤検知する（検証で発生し、この条件で解消）<br>・ログには VM 名が無い。1 グループに VM 1 台なので、グループ名がそのまま VM を表す（`ipAddress` でも特定できる）<br>・GCP 側（A1）の実測はアプリ停止から約 23 秒<br>・除外: なし |

### 1.3 補足

| 項目 | 内容 |
|---|---|
| M1 はリクエストが無いと鳴らない | 5xx のログは ALB が実際に返したレスポンスの記録なので、リクエストが来なければ全台停止でも 0 件のまま。死活の判断は M2・M5 に任せる |
| M1 は 1 台の停止ではほぼ鳴らない | ALB がもう 1 台に振り分けるので、5xx は停止の瞬間に 1 件程度（警告止まり） |
| M5 の「回復」は回復を意味しない | ログは状態が変わったときに 1 件出るだけで、UNHEALTHY が続いても繰り返し出ない。遷移ログから 5 分たつと、異常が続いていてもモニターは「回復」になる。実際の回復は `UNHEALTHY→HEALTHY` のログか `gcloud compute backend-services get-health vas-bes --region=asia-northeast1` で確認する |
| M5 は VM の停止では鳴らない | VM が停止（TERMINATED）すると、1 台でも 2 台でもヘルスチェックログが出ない（検証で確認）。停止した VM はヘルスチェックの対象から外れ、`get-health` の一覧からも消える。VM の停止は M2 で拾う |
| ヘルスチェックの URL | 今は `/`（業務と同じ URL）を確認している。ヘルスチェック専用の URL に変えると、「ヘルスチェックは正常だが業務の URL で 5xx」という状態は M1 でしか分からなくなる |

---

## 2. Compute Engine

### 2.1 前提

| 項目 | 内容 |
|---|---|
| VM | `vas-web-1`（asia-northeast1-a）、`vas-web-2`（asia-northeast1-b） |
| 指標（M2） | `compute.googleapis.com/instance/uptime`（Datadog: `gcp.gce.instance.uptime`）。1 分ごとの「その 1 分間に VM が動いていた秒数」。動いていれば約 60、停止すると **値が届かなくなる**（0 にはならない） |
| 監査ログ（M4） | logName: `projects/miumosh-sb-test01/logs/cloudaudit.googleapis.com%2Factivity`<br>resource.type: `gce_instance`<br>methodName: `v1.compute.instances.start`／`v1.compute.instances.stop`<br>保存先: GCP は `_Required` ログバケット（保持 400 日、変更不可）／Datadog はログインデックス `main` |
| 監査ログの重要度 | 正常な起動・停止は、処理開始（`operation.first=true`）と完了（`operation.last=true`）の 2 件が `NOTICE`。403 で拒否されると `ERROR` が 1 件出て、`protoPayload.status.code=7` が付く（検証で確認） |

### 2.2 監視するメトリクスの詳細（M2）

| ID | 分類 | 監視対象メトリクス | 評価期間 | アラート判定条件 | 閾値（危険） | 閾値（警告） | 解説 |
|---|---|---|---|---|---|---|---|
| M2 | 死活 | `gcp.gce.instance.uptime`（対象: `project_id:miumosh-sb-test01`、`instance_name:vas-web-*`、VM 別）。値が届かない時間を 0 として扱う（`default_zero()`） | 直近 10 分の平均（`avg(last_10m)`）。`evaluation_delay: 300`（GCP 指標の取り込み遅延の吸収。要調整） | 閾値以下になったら（メトリクス <= 閾値） | **0**（直近 10 分間ずっと停止していた） | **30**（直近 10 分のうち約半分以上停止していた） | ・モニタークエリ: `avg(last_10m):default_zero(avg:gcp.gce.instance.uptime{project_id:miumosh-sb-test01,instance_name:vas-web-*} by {instance_name}) <= 0`<br>・その他: `require_full_window: false`、`notify_no_data: false`、`renotify_interval: 60`<br>・平均を使うのは、取り込みの揺らぎで 1 点欠けても誤検知しないため（最小値だと 1 点の欠けで鳴る）<br>・ALB のヘルスチェックログは VM 停止では出ないので、VM 停止の検知はこの監視が担う<br>・導入時に、Datadog 上で正常時の値が約 60 であることを確認する（違えば、警告を正常値の半分にする） |

**閾値の計算式**

10 分間の平均値 ＝（1 分ごとの値の合計）÷ 10
＝（60 × 動いていた分数 ＋ 0 × 止まっていた分数）÷ 10

| 直近 10 分の状態 | 計算 | 平均値 | 判定 |
|---|---|---|---|
| ずっと動いていた | （60 × 10 ＋ 0 × 0）÷ 10 | 60 | 正常 |
| 1 分止まっていた（または 1 点取り込み漏れ） | （60 × 9 ＋ 0 × 1）÷ 10 | 54 | 正常 |
| 3 分止まっていた | （60 × 7 ＋ 0 × 3）÷ 10 | 42 | 正常 |
| **5 分止まっていた** | （60 × 5 ＋ 0 × 5）÷ 10 | **30** | **警告（≦ 30）** |
| 8 分止まっていた | （60 × 2 ＋ 0 × 8）÷ 10 | 12 | 警告 |
| **10 分ずっと止まっていた** | （60 × 0 ＋ 0 × 10）÷ 10 | **0** | **危険（≦ 0）** |

- 一般式: 警告の閾値 ＝ 60 ×（10 − 警告にしたい停止分数）÷ 10。例: 3 分以上で警告にしたいなら 60 × 7 ÷ 10 ＝ 42

### 2.3 ログ監視の詳細（M4）

| ID | 監視対象 | エラー判定文字列（GCP） | Datadog の条件 | 評価・閾値 | 解説 |
|---|---|---|---|---|---|
| M4 | 起動・停止の失敗（監査ログ） | `logName="projects/miumosh-sb-test01/logs/cloudaudit.googleapis.com%2Factivity" resource.type="gce_instance" protoPayload.serviceName="compute.googleapis.com" protoPayload.methodName=~"compute\.instances\.(start\|stop)$" protoPayload.resourceName=~"/instances/vas-web-[0-9]+$" severity>=ERROR` | `@resource.type:gce_instance @protoPayload.methodName:(*compute.instances.start OR *compute.instances.stop) @protoPayload.resourceName:*vas-web-* (status:(error OR critical OR alert OR emergency) OR @protoPayload.status.code:>0)` | 直近 5 分の件数。≧ 1 件 → 危険（警告なし）。VM（`protoPayload.resourceName`）別 | ・methodName を後方一致にするのは、API のバージョンで接頭辞（`v1.`、`beta.`）が変わるため<br>・Datadog 側は、既存の Workflows の監視と同じく、ログレベルと GCP のエラーコード（`status.code`）を OR にしている（GCP 側は `severity>=ERROR` のみ。権限不足は両方を満たすので、検証した範囲では同じ結果）<br>・受付後の処理の失敗（リソース不足など）は、完了ログが ERROR になる想定（未再現）<br>・GCP 側（S3）の実測は失敗から約 20〜49 秒<br>・除外: 運用者や CI の手動操作の失敗を通知しない場合だけ、GCP は `NOT protoPayload.authenticationInfo.principalEmail="<運用者・CI のアカウント>"`、Datadog は `-@protoPayload.authenticationInfo.principalEmail:<運用者・CI のアカウント>` |

---

## 3. Cloud Scheduler

### 3.1 前提

| 項目 | 内容 |
|---|---|
| ジョブ | `vas-web-1-start`、`vas-web-1-stop`、`vas-web-2-start`、`vas-web-2-stop`（ロケーション `asia-northeast1`） |
| 実行 SA | `vas-scheduler@miumosh-sb-test01.iam.gserviceaccount.com`（VM 単位の権限） |
| ジョブの設定 | `retry_count = 0`、`attempt_deadline = 60s`（1 回の失敗で確定） |
| ログ | logName: `projects/miumosh-sb-test01/logs/cloudscheduler.googleapis.com%2Fexecutions`<br>resource.type: `cloud_scheduler_job`<br>実行ごとに `AttemptStarted`（INFO）と `AttemptFinished` が出る。失敗時は `AttemptFinished` が `ERROR` になり、`jsonPayload.status`（例: `PERMISSION_DENIED`）と `httpRequest.status`（例: 403）が付く |

- **M3 と M4 は必ずセットで使う**。Scheduler の実行ログに残るのは Compute API の受付結果（HTTP 応答）だけ。受付後に起動・停止の処理が失敗しても（例: `ZONE_RESOURCE_POOL_EXHAUSTED`）、Scheduler 上は 200 の成功になる。この失敗は M4 でしか拾えない

### 3.2 監視の詳細

| ID | 監視対象 | エラー判定文字列（GCP） | Datadog の条件 | 評価・閾値 | 解説 |
|---|---|---|---|---|---|
| M3 | ジョブの実行失敗 | `logName="projects/miumosh-sb-test01/logs/cloudscheduler.googleapis.com%2Fexecutions" resource.type="cloud_scheduler_job" resource.labels.job_id=~"^vas-web-.*-(start\|stop)$" jsonPayload."@type"="type.googleapis.com/google.cloud.scheduler.logging.AttemptFinished" severity>=ERROR` | `@resource.type:cloud_scheduler_job @resource.labels.job_id:vas-web-* status:(error OR critical OR alert OR emergency)` | 直近 5 分の件数。≧ 1 件 → 危険（警告なし）。`job_id` 別 | ・`job_id` で VM 起動・停止の 4 ジョブに絞る（同じプロジェクトの他のジョブを拾わない）<br>・Datadog 側は `AttemptFinished` の条件を入れていないが、ERROR になるのは `AttemptFinished` だけなので結果は同じ<br>・`logName` を入れるのは、Cloud Monitoring のアラートのイベントログが同じ `resource.type` で記録されるため（Datadog にはシンクで絞ったログしか届かないので不要）<br>・`@protoPayload.status.code` は使わない（Scheduler の実行ログにこの項目は無い）<br>・GCP 側（S1）の実測は失敗から約 35〜49 秒<br>・除外: 検証用に意図的に失敗させるジョブ。GCP は `NOT resource.labels.job_id="vas-failure-test"`、Datadog は `-@resource.labels.job_id:vas-failure-test`（本番では作らない） |

---

## 4. 検知時間（Datadog、推定）

詳細は [monitor-result-datadog-time.md](monitor-result-datadog-time.md)。

| ID | 検知する事象 | リクエストが必要か | 通知までの目安（Datadog、推定） | 参考: GCP 側の実測 |
|---|---|---|---|---|
| M1 | 全台停止、業務 URL のエラー、ALB の異常 | **必要** | 停止の操作から約 1.5〜3.5 分 | A2: 正確な値は取れていない |
| M2 | VM 停止（1 台ずつ） | 不要 | 警告 約 10 分／危険 約 15 分 | A5（途絶 180 秒の条件）: 約 8.7 分 |
| M3 | 起動・停止ジョブの失敗 | 不要 | ジョブの実行から約 1〜3 分 | S1: 約 35〜49 秒 |
| M4 | 起動・停止 API の失敗 | 不要 | 操作から約 1〜3 分 | S3: 約 20〜49 秒 |
| M5 | アプリの停止・ハング | 不要 | アプリ停止から約 1〜3 分 | A1: 約 23 秒 |

- ログの監視（M1・M3・M4・M5）は「事象が起きたことを数える」ので分単位。M2 は「値が来なくなった」ことを、止まった時間が積み上がるまで待つので 10 分以上（さらに evaluation_delay の 5 分が加わる）

---

## 5. 検知できること・できないこと

| 事象 | M1 5xx | M2 Uptime | M3 Scheduler | M4 監査 | M5 ヘルスチェック | 備考 |
|---|---|---|---|---|---|---|
| VM 1 台が停止（Scheduler による計画停止） | △ 警告（1 件程度） | ◯ | – | – | × | 計画停止なので M2 は Downtime で抑止 |
| VM 1 台が予期せず停止（手動操作・障害） | △ 警告（1 件程度） | ◯ | – | – | × | ゲスト OS 内からの shutdown・ホストの障害は監査ログ（activity）に出ない。M2 で拾う |
| VM 2 台とも停止（リクエストあり） | ◯ 危険 | ◯ | – | – | × | 最初に気づけるのは M1 |
| VM 2 台とも停止（**リクエストなし**。夜間など） | × | ◯ | – | – | × | M2 だけが拾う |
| VM は動いているがアプリが停止・ハング（1 台） | △ 警告（数件。リクエストが無ければ 0 件） | × | – | – | **◯** | M5 はリクエストが無くても拾う |
| VM は動いているがアプリが停止・ハング（2 台とも） | ◯ 危険（リクエストがあれば） | × | – | – | **◯（VM ごとに発報）** | リクエストが無い時間帯は M5 だけが拾う |
| ヘルスチェックの URL は正常だが、業務の URL で 5xx | ◯（リクエストがあれば） | × | – | – | × | ヘルスチェック専用の URL に変えた場合に起こりうる |
| ALB 自体の設定ミス・障害 | ◯（リクエストがあれば） | × | – | – | × | |
| Scheduler の権限不足（403） | – | – | ◯ | ◯ | – | 検証で確認（T4、T5） |
| API が受付時点で拒否（4xx） | – | – | ◯ | ◯ | – | 403 と同じ仕組み。未検証 |
| 受付後に起動・停止の処理が失敗（リソース不足など） | – | 起動失敗なら × のまま（もともと停止中） | **×（200 の成功に見える）** | ◯（想定） | – | 未再現 |
| Scheduler が Compute API に到達できない・タイムアウト | – | – | ◯ | × | – | 未検証 |
| ジョブが実行されない（一時停止、削除、スケジュールの設定ミス） | – | – | × | × | – | ログ自体が出ない。メンテナンス当日に実行履歴を確認する |

---

## 6. 月次メンテナンス時の扱い

| ID | メンテナンス中 | 理由 |
|---|---|---|
| M1 | 2 台同時停止なら Downtime。ローリング（1 台ずつ）なら抑止しない | ローリングなら 5xx は 1 件程度で警告止まり。危険が出たら、ローリングが崩れている |
| M2 | Downtime（対象: `instance_name:vas-web-*`、停止ジョブの時刻から起動ジョブの時刻＋20 分まで） | 計画停止そのものを検知してしまう。Downtime の終了後も値が戻らなければ、起動の失敗に気づける |
| M3 | 抑止しない | メンテナンスで一番検知したい事象（起動・停止の失敗） |
| M4 | 抑止しない | 同上。M3 では見えない受付後の失敗を拾う |
| M5 | 抑止しない | VM の停止ではログが出ず、起動時の詳細状態だけの変化は `previousHealthState` の条件で除外される（検証で確認）。本番の停止で発報した場合は Downtime の対象に加える |

- Downtime の設定例（`datadog_downtime_schedule`）は [monitor-result-datadog.md](monitor-result-datadog.md) の 4.1

---

## 7. Datadog へのログ転送（シンクのフィルタ）

```
(logName="projects/miumosh-sb-test01/logs/loadbalancing.googleapis.com%2Frequests"
  AND resource.type="internal_http_lb_rule"
  AND resource.labels.forwarding_rule_name="vas-fr-http"
  AND httpRequest.status>=500)
OR
(logName="projects/miumosh-sb-test01/logs/cloudscheduler.googleapis.com%2Fexecutions"
  AND resource.type="cloud_scheduler_job")
OR
(logName="projects/miumosh-sb-test01/logs/cloudaudit.googleapis.com%2Factivity"
  AND resource.type="gce_instance"
  AND protoPayload.methodName=~"compute\.instances\.(start|stop)$")
OR
(logName="projects/miumosh-sb-test01/logs/compute.googleapis.com%2Fhealthchecks"
  AND resource.type="gce_instance_group")
```

| 転送するログ | 対象の監視 | 件数の目安 | 理由 |
|---|---|---|---|
| ALB のリクエストログ（5xx だけ） | M1 | 障害時だけ | 全リクエストを送ると、2 秒ごとのリクエストだけで約 1,300 件／時になる |
| Scheduler の実行ログ（成功も含む） | M3 | 1 ジョブ 1 回あたり 2 件 | 成功・失敗の履歴を Datadog 上で追えるようにする |
| 監査ログの起動・停止（成功も含む） | M4 | 1 回の操作あたり 2 件 | 「誰が・いつ起動・停止したか」を Datadog 上で確認できるようにする |
| ヘルスチェックログ（すべての遷移） | M5 | 状態が変わったときだけ（検証全体で 17 件） | `UNHEALTHY→HEALTHY` も送り、M5 の通知が「回復」になった後に実際に戻ったかを確認できるようにする |

- [datadog/log_forwarding.tf](datadog/log_forwarding.tf) の `forward_filter` に相当する
- 追加の監視（[monitor-additional.md](monitor-additional.md)）を入れる場合は、その 6 章のフィルタを OR で追加する

---

## 8. 未検証の事項と、本番導入前に確認すること

| 項目 | 内容 |
|---|---|
| Datadog 側の実装 | Datadog への取り込み・モニターは動かしていない。属性名の書き方、取り込みの遅れを導入時に確認する（[monitor-result-datadog.md](monitor-result-datadog.md) の 5 章） |
| M1 の危険の閾値 | 検証の 2 秒ごとのリクエストを前提にした値。本番のリクエスト量で見直す |
| M2 の遅延 | GCP 側（A5）の実測は約 8.7 分。Datadog では evaluation_delay の分も加わる。取り込みの遅れを測ってから evaluation_delay を決める |
| M4 の受付後の失敗 | `ZONE_RESOURCE_POOL_EXHAUSTED` などの非同期の失敗は再現できていない |
| M5 の停止時の挙動 | 検証では、Scheduler による停止で HEALTHY→UNHEALTHY のログは出なかった。本番のアプリのシャットダウンが遅い場合はログが出る可能性がある |
| M5 の回復の確認 | 通知上の「回復」は、遷移ログから 5 分たっただけ。実際の回復は HEALTHY 遷移のログか `get-health` で確認する運用にする |
| ログの取り込みの遅れ | 5 分を超える場合、ログ監視の評価範囲（直近 5 分）から外れて数えられない可能性がある |

---

## 参考

- 検証の結果・時系列: [RESULTS.md](RESULTS.md)、[test-history.md](test-history.md)
- ログの形式・挙動の知見: [KNOWLEDGE.md](KNOWLEDGE.md)
- 監視の設計（GCP 側の条件の詳細）: [monitoring-result.md](monitoring-result.md)
- Datadog のモニター設定（通知メッセージ・Terraform・Downtime・導入手順）: [monitor-result-datadog.md](monitor-result-datadog.md)
- 検知時間の比較: [monitor-result-datadog-time.md](monitor-result-datadog-time.md)
- 追加の監視（Certificate Manager／Backup and DR／Oracle Autonomous AI Database／Compute Engine のイベント）: [monitor-additional.md](monitor-additional.md)
