# Datadog 監視設定

[monitoring-result.md](monitoring-result.md) で決めた 4 つの監視（M1〜M4）を、Datadog のモニターとして実装するための設定値。

- monitoring-result.md: 何を・どの条件で監視するか（GCP 側のログの条件は Cloud Logging の検索クエリで記載）
- このドキュメント: その条件を Datadog の検索クエリとモニター設定に書き直したもの

> 注意: Datadog への取り込みとモニターは、今回の検証では動かしていない（未検証）。導入時は「6. 導入時の確認手順」で、検索クエリが想定どおりのログに一致するかを確認してから有効化する。

---

## 1. 前提

| 項目 | 内容 |
|---|---|
| 指標の取り込み | Datadog GCP インテグレーション（STS）。`gcp.gce.instance.uptime` などに `project_id`、`instance_name`、`zone` のタグが付く |
| ログの取り込み | Log Router シンク → Pub/Sub → Dataflow（`Cloud_PubSub_to_Datadog`）→ Datadog Logs（[datadog/log_forwarding.tf](datadog/log_forwarding.tf)、シンクのフィルタは monitoring-result.md の 3.3） |
| ログの属性パス | GCP の LogEntry は `@data.` の下に入る想定（例: GCP の `resource.type` → Datadog の `@data.resource.type`） |
| ログインデックス | `main`（モニターのクエリは `.index("*")` で全インデックスを対象にする） |
| 通知先 | `@<通知先>`（例: `@slack-ops-alert`、`@ops@example.com`）。以下では `@notify` と書く |

### 1.1 事前に作るファセット・メジャー

グループ化や範囲検索に使う属性は、Datadog の Log Explorer でファセット（数値はメジャー）として登録しておく。登録しないと、範囲検索（`>=`）とグループ化（`.by()`）が使えない。

| 属性 | 種類 | 使う監視 | 用途 |
|---|---|---|---|
| `@data.httpRequest.status` | メジャー（integer） | M1 | 5xx の範囲検索 |
| `@data.resource.labels.forwarding_rule_name` | ファセット | M1 | ALB の絞り込み |
| `@data.resource.labels.job_id` | ファセット | M3 | ジョブ別のグループ化 |
| `@data.protoPayload.methodName` | ファセット | M4 | メソッドの絞り込み |
| `@data.protoPayload.resourceName` | ファセット | M4 | VM 別のグループ化 |
| `@data.severity` | ファセット | M3、M4 | ERROR の絞り込み |

---

## 2. モニター一覧

| ID | モニター名 | タイプ | 判定 | 危険 | 警告 | メンテナンス中 |
|---|---|---|---|---|---|---|
| M1 | `[M1][log] 内部ALB 5xx応答` | Log Monitor（`log alert`） | 5 分間の 5xx ログ件数 | ≧ 20 | ≧ 1 | 2 台同時停止なら Downtime |
| M2 | `[M2][metric] VM停止（Uptime途絶）` | Metric Monitor（`query alert`） | `instance_name` 別の No Data | No Data 15 分 | – | Downtime |
| M3 | `[M3][log] Cloud Schedulerジョブ失敗` | Log Monitor（`log alert`） | 5 分間の失敗ログ件数（ジョブ別） | ≧ 1 | – | 抑止しない |
| M4 | `[M4][log] Compute起動停止の失敗（監査ログ）` | Log Monitor（`log alert`） | 5 分間の失敗ログ件数（VM 別） | ≧ 1 | – | 抑止しない |

---

## 3. 各モニターの設定

### 3.1 M1: 内部 ALB 5xx 応答（ALB のリクエストログ）

| 項目 | 設定値 |
|---|---|
| エラー判定文字列（Datadog の検索クエリ） | `@data.logName:*loadbalancing.googleapis.com%2Frequests @data.resource.type:internal_http_lb_rule @data.resource.labels.project_id:miumosh-sb-test01 @data.resource.labels.forwarding_rule_name:vas-fr-http @data.httpRequest.status:>=500 @data.httpRequest.status:<600` |
| 除外文字列 | `-@data.httpRequest.userAgent:GoogleStackdriverMonitoring*`（GCP の Uptime Check を併用する場合）<br>`-@data.httpRequest.requestUrl:*healthz*`（アプリ独自の死活確認パスの 5xx を別に監視する場合。パスは環境に合わせる） |
| モニタークエリ | `logs("<エラー判定文字列> <除外文字列>").index("*").rollup("count").last("5m") >= 20` |
| 閾値 | critical: `20`／warning: `1`（比較演算子は `>=`） |
| グループ化 | なし（全台停止では `backend_name` が空になるため、まとめて数える） |
| オプション | `notify_no_data: false`、`enable_logs_sample: true`、`renotify_interval: 60`、`on_missing_data: resolve` |

通知メッセージ:

```
{{#is_alert}}
[危険] 内部 ALB（vas-fr-http）が 5 分間に {{value}} 件の 5xx を返しました。
全台停止の可能性があります。VM の状態とバックエンドのヘルスを確認してください。
  gcloud compute instances list --filter="name~^vas-web-"
  gcloud compute backend-services get-health vas-bes --region=asia-northeast1
{{/is_alert}}
{{#is_warning}}
[警告] 内部 ALB（vas-fr-http）が 5xx を返しました（{{value}} 件／5 分）。
1 台の停止・アプリ停止の切り替わりで数件出ることがあります。継続する場合は確認してください。
{{/is_warning}}
{{#is_recovery}}内部 ALB の 5xx が収まりました。{{/is_recovery}}
@notify
```

### 3.2 M2: VM 停止（Compute Engine の Uptime）

| 項目 | 設定値 |
|---|---|
| 監視対象メトリクス | `gcp.gce.instance.uptime` |
| モニタークエリ | `avg(last_10m):avg:gcp.gce.instance.uptime{project_id:miumosh-sb-test01,instance_name:vas-web-*} by {instance_name} < 0` |
| 閾値 | critical: `0`（値では発報しない。判定は No Data だけ） |
| No Data | `notify_no_data: true`、`no_data_timeframe: 15`（分） |
| オプション | `evaluation_delay: 300`（秒。GCP 指標の取り込み遅延を吸収）、`require_full_window: false`、`renotify_interval: 60` |

- `< 0` は「値では絶対に発報しない」ためのダミー条件。uptime は 0 以上なので、発報するのは No Data のときだけになる
- No Data の判定は、一度データが届いたグループ（`instance_name`）に対して行われる。VM を新しく追加した場合は、データが届いた時点から対象になる

通知メッセージ:

```
{{#is_no_data}}
[危険] VM {{instance_name.name}} の uptime 指標が 15 分間届いていません（VM 停止の可能性）。
  gcloud compute instances describe {{instance_name.name}} --zone=<ZONE> --format="value(status)"
月次メンテナンス中でないか確認してください。
{{/is_no_data}}
{{#is_no_data_recovery}}VM {{instance_name.name}} の uptime 指標が戻りました。{{/is_no_data_recovery}}
@notify
```

### 3.3 M3: Cloud Scheduler ジョブ失敗（ジョブの実行ログ）

| 項目 | 設定値 |
|---|---|
| エラー判定文字列（Datadog の検索クエリ） | `@data.logName:*cloudscheduler.googleapis.com%2Fexecutions @data.resource.type:cloud_scheduler_job @data.resource.labels.project_id:miumosh-sb-test01 @data.resource.labels.job_id:vas-web-* @data.severity:ERROR` |
| 除外文字列 | `-@data.resource.labels.job_id:vas-failure-test`（検証用に意図的に失敗させるジョブ。`vas-web-*` の条件で既に対象外だが、命名を変えたときの保険） |
| モニタークエリ | `logs("<エラー判定文字列> <除外文字列>").index("*").rollup("count").by("@data.resource.labels.job_id").last("5m") > 0` |
| 閾値 | critical: `0`（比較演算子は `>`。1 件以上で発報）／warning: なし |
| グループ化 | `@data.resource.labels.job_id`（ジョブごとに通知） |
| オプション | `notify_no_data: false`、`enable_logs_sample: true`、`renotify_interval: 0`、`on_missing_data: resolve` |

- 実行ログの種類（`jsonPayload.@type`）は条件に入れていない。`@type` は属性名に `@` を含み、Datadog の検索で指定しにくいため。代わりに `severity:ERROR` で絞る。実行開始のログ（AttemptStarted）は常に INFO なので、ERROR になるのは実行結果のログ（AttemptFinished）だけ。検証時の開始ログ 11 件はすべて INFO だった
- 通知にエラー内容を出すため、`enable_logs_sample` でログのサンプル（`jsonPayload.status`、`httpRequest.status`、`jsonPayload.url`）を添付する

通知メッセージ:

```
{{#is_alert}}
[危険] Cloud Scheduler ジョブ {{[@data.resource.labels.job_id].name}} の実行が失敗しました。
VM の起動・停止が行われていません。添付のログで jsonPayload.status（例: PERMISSION_DENIED）を確認してください。
  gcloud scheduler jobs describe {{[@data.resource.labels.job_id].name}} --location=asia-northeast1
対処後、手動で再実行してください。
  gcloud scheduler jobs run {{[@data.resource.labels.job_id].name}} --location=asia-northeast1
{{/is_alert}}
@notify
```

### 3.4 M4: Compute 起動・停止の失敗（監査ログ）

| 項目 | 設定値 |
|---|---|
| エラー判定文字列（Datadog の検索クエリ） | `@data.logName:*cloudaudit.googleapis.com%2Factivity @data.resource.type:gce_instance @data.resource.labels.project_id:miumosh-sb-test01 @data.protoPayload.serviceName:compute.googleapis.com @data.protoPayload.methodName:(*compute.instances.start OR *compute.instances.stop) @data.protoPayload.resourceName:*vas-web-* @data.severity:ERROR` |
| 除外文字列 | `-@data.protoPayload.authenticationInfo.principalEmail:<運用者・CI のアカウント>`（Scheduler 以外の手動操作の失敗を通知しない場合。手動操作の失敗も通知したいなら設定しない） |
| モニタークエリ | `logs("<エラー判定文字列> <除外文字列>").index("*").rollup("count").by("@data.protoPayload.resourceName").last("5m") > 0` |
| 閾値 | critical: `0`（比較演算子は `>`。1 件以上で発報）／warning: なし |
| グループ化 | `@data.protoPayload.resourceName`（VM ごとに通知） |
| オプション | `notify_no_data: false`、`enable_logs_sample: true`、`renotify_interval: 0`、`on_missing_data: resolve` |

- `methodName` は前方を `*` にする。API のバージョンで接頭辞が変わるため（`v1.compute.instances.start`、`beta.compute.instances.start`）。末尾は固定なので、`instances.startWithEncryptionKey` などの別メソッドは拾わない
- 権限不足（403）では、`protoPayload.status.code: 7` と `protoPayload.status.message`（例: `Required 'compute.instances.stop' permission for ...`）が付く（検証で確認）。受付後の処理の失敗では、完了ログ（`operation.last: true`）が ERROR になる想定（未再現）

通知メッセージ:

```
{{#is_alert}}
[危険] Compute Engine の起動・停止が失敗しました: {{[@data.protoPayload.resourceName].name}}
添付のログの protoPayload.status.message と authenticationInfo.principalEmail を確認してください。
Scheduler のジョブが「成功」になっていても、受付後の処理で失敗している場合があります。
  gcloud compute instances describe <VM名> --zone=<ZONE> --format="value(status)"
{{/is_alert}}
@notify
```

---

## 4. Terraform（datadog provider）

上の設定を `datadog_monitor` で書いたもの。検索クエリに `"` や `\` を含めていないので、HCL のエスケープは不要。

```hcl
locals {
  project_id = "miumosh-sb-test01"
  notify     = "@notify" # 通知先に置き換える

  q_m1 = join(" ", [
    "@data.logName:*loadbalancing.googleapis.com%2Frequests",
    "@data.resource.type:internal_http_lb_rule",
    "@data.resource.labels.project_id:${local.project_id}",
    "@data.resource.labels.forwarding_rule_name:vas-fr-http",
    "@data.httpRequest.status:>=500",
    "@data.httpRequest.status:<600",
    "-@data.httpRequest.userAgent:GoogleStackdriverMonitoring*",
  ])

  q_m3 = join(" ", [
    "@data.logName:*cloudscheduler.googleapis.com%2Fexecutions",
    "@data.resource.type:cloud_scheduler_job",
    "@data.resource.labels.project_id:${local.project_id}",
    "@data.resource.labels.job_id:vas-web-*",
    "@data.severity:ERROR",
    "-@data.resource.labels.job_id:vas-failure-test",
  ])

  q_m4 = join(" ", [
    "@data.logName:*cloudaudit.googleapis.com%2Factivity",
    "@data.resource.type:gce_instance",
    "@data.resource.labels.project_id:${local.project_id}",
    "@data.protoPayload.serviceName:compute.googleapis.com",
    "@data.protoPayload.methodName:(*compute.instances.start OR *compute.instances.stop)",
    "@data.protoPayload.resourceName:*vas-web-*",
    "@data.severity:ERROR",
  ])

  tags = ["service:vm-alb-scheduler", "managed-by:terraform"]
}

resource "datadog_monitor" "m1_ilb_5xx" {
  name    = "[M1][log] 内部ALB 5xx応答"
  type    = "log alert"
  query   = "logs(\"${local.q_m1}\").index(\"*\").rollup(\"count\").last(\"5m\") >= 20"
  message = <<-EOT
    {{#is_alert}}[危険] 内部 ALB（vas-fr-http）が 5 分間に {{value}} 件の 5xx を返しました。全台停止の可能性があります。{{/is_alert}}
    {{#is_warning}}[警告] 内部 ALB（vas-fr-http）が 5xx を返しました（{{value}} 件／5 分）。{{/is_warning}}
    {{#is_recovery}}内部 ALB の 5xx が収まりました。{{/is_recovery}}
    ${local.notify}
  EOT

  monitor_thresholds {
    critical = 20
    warning  = 1
  }

  enable_logs_sample = true
  notify_no_data     = false
  on_missing_data    = "resolve"
  renotify_interval  = 60
  tags               = concat(local.tags, ["monitor:m1"])
}

resource "datadog_monitor" "m2_vm_uptime" {
  name    = "[M2][metric] VM停止（Uptime途絶）"
  type    = "query alert"
  query   = "avg(last_10m):avg:gcp.gce.instance.uptime{project_id:${local.project_id},instance_name:vas-web-*} by {instance_name} < 0"
  message = <<-EOT
    {{#is_no_data}}[危険] VM {{instance_name.name}} の uptime 指標が 15 分間届いていません（VM 停止の可能性）。{{/is_no_data}}
    {{#is_no_data_recovery}}VM {{instance_name.name}} の uptime 指標が戻りました。{{/is_no_data_recovery}}
    ${local.notify}
  EOT

  monitor_thresholds {
    critical = 0
  }

  notify_no_data      = true
  no_data_timeframe   = 15
  evaluation_delay    = 300
  require_full_window = false
  renotify_interval   = 60
  tags                = concat(local.tags, ["monitor:m2"])
}

resource "datadog_monitor" "m3_scheduler_failed" {
  name    = "[M3][log] Cloud Schedulerジョブ失敗"
  type    = "log alert"
  query   = "logs(\"${local.q_m3}\").index(\"*\").rollup(\"count\").by(\"@data.resource.labels.job_id\").last(\"5m\") > 0"
  message = <<-EOT
    {{#is_alert}}[危険] Cloud Scheduler ジョブ {{[@data.resource.labels.job_id].name}} の実行が失敗しました。VM の起動・停止が行われていません。{{/is_alert}}
    ${local.notify}
  EOT

  monitor_thresholds {
    critical = 0
  }

  enable_logs_sample = true
  notify_no_data     = false
  on_missing_data    = "resolve"
  tags               = concat(local.tags, ["monitor:m3"])
}

resource "datadog_monitor" "m4_compute_op_failed" {
  name    = "[M4][log] Compute起動停止の失敗（監査ログ）"
  type    = "log alert"
  query   = "logs(\"${local.q_m4}\").index(\"*\").rollup(\"count\").by(\"@data.protoPayload.resourceName\").last(\"5m\") > 0"
  message = <<-EOT
    {{#is_alert}}[危険] Compute Engine の起動・停止が失敗しました: {{[@data.protoPayload.resourceName].name}}{{/is_alert}}
    ${local.notify}
  EOT

  monitor_thresholds {
    critical = 0
  }

  enable_logs_sample = true
  notify_no_data     = false
  on_missing_data    = "resolve"
  tags               = concat(local.tags, ["monitor:m4"])
}
```

### 4.1 月次メンテナンスの Downtime（M1・M2）

```hcl
resource "datadog_downtime_schedule" "monthly_maintenance" {
  scope = "project_id:miumosh-sb-test01"

  monitor_identifier {
    monitor_tags = ["monitor:m2"] # 2 台同時停止の運用なら "monitor:m1" も対象にする
  }

  recurring_schedule {
    timezone = "Asia/Tokyo"
    recurrence {
      rrule    = "FREQ=MONTHLY;BYDAY=1SA" # 例: 第 1 土曜。メンテナンス日に合わせる
      start    = "2026-12-05T01:50:00"    # 停止ジョブの 10 分前
      duration = "4h"                     # 起動ジョブの時刻＋20 分まで
    }
  }

  display_timezone = "Asia/Tokyo"
  message          = "月次メンテナンス（Cloud Scheduler による VM 停止・起動）"
}
```

- M3・M4 は Downtime の対象にしない（メンテナンスで一番検知したいのが起動・停止の失敗のため）
- Downtime の終了後に M2 の No Data が続いていれば、起動に失敗している

---

## 5. エラー判定文字列の書き方の注意

| 注意点 | 内容 |
|---|---|
| `/` は使わない | Datadog の検索では `/` が特殊文字で、エスケープ（`\/`）が必要になる。Terraform のクエリ文字列の中では二重のエスケープになり、間違えやすい。そのため `logName` は `*loadbalancing.googleapis.com%2Frequests` のように、`/` を含まない後方一致で書いている。`resourceName` も `*vas-web-*` で書いている |
| `"` は使わない | モニタークエリの `logs("...")` の中で `"` を使うと、エスケープ（`\"`）が必要になる。値に空白や記号を含まない書き方にしている |
| 数値の範囲 | `@data.httpRequest.status:>=500` はメジャー登録が前提。ファセット未登録だと文字列として扱われ、一致しない |
| `severity` | ALB のリクエストログは 5xx でも `WARNING` なので、M1 では `severity` を使わない。M3・M4 は失敗時に `ERROR` になる |
| `-`（NOT）の位置 | 除外は検索クエリの末尾に `-@属性:値` で追加する。複数あれば空白で並べる（AND） |
| ワイルドカード | `*` は値の前後どちらにも使える（例: `*compute.instances.start`）。値の途中の `-`（`vas-web-*`）はエスケープ不要 |

### 5.1 Cloud Logging の検索クエリとの対応

| 条件 | Cloud Logging（monitoring-result.md） | Datadog（このドキュメント） |
|---|---|---|
| ログ名 | `logName="projects/miumosh-sb-test01/logs/loadbalancing.googleapis.com%2Frequests"` | `@data.logName:*loadbalancing.googleapis.com%2Frequests` |
| リソース種別 | `resource.type="internal_http_lb_rule"` | `@data.resource.type:internal_http_lb_rule` |
| 数値の範囲 | `httpRequest.status>=500 httpRequest.status<600` | `@data.httpRequest.status:>=500 @data.httpRequest.status:<600` |
| 正規表現・前方一致 | `resource.labels.job_id=~"^vas-web-.*-(start\|stop)$"` | `@data.resource.labels.job_id:vas-web-*` |
| 後方一致 | `protoPayload.methodName=~"compute\.instances\.(start\|stop)$"` | `@data.protoPayload.methodName:(*compute.instances.start OR *compute.instances.stop)` |
| 重大度 | `severity>=ERROR` | `@data.severity:ERROR` |
| 除外 | `NOT resource.labels.job_id="vas-failure-test"` | `-@data.resource.labels.job_id:vas-failure-test` |

---

## 6. 導入時の確認手順

1. Log Explorer でエラー判定文字列（除外を含む）を検索する。過去のログで一致する件数が 0 になることを確認する（正常時に誤検知しないこと）
2. 検索した結果のログを開き、`@data.` の下の属性パスが想定どおりかを確認する。違う場合は、このドキュメントのクエリを修正する
3. 1.1 のファセット・メジャーを登録する
4. モニターを作成し、通知先をテスト用にした状態で、失敗を意図的に起こして発報を確認する
   - M3・M4: Scheduler の SA から VM の権限を外して、ジョブを手動実行する（`gcloud scheduler jobs run`。検証の T5 と同じ）
   - M1・M2: VM を 2 台とも停止する（検証の T2 と同じ）
5. 通知先を本番用に切り替える

---

## 7. 既存サンプル（datadog/monitors.tf）との違い

[datadog/monitors.tf](datadog/monitors.tf) は検証前に作ったサンプルで、このドキュメントとは次の点が違う。

| 項目 | datadog/monitors.tf | このドキュメント |
|---|---|---|
| 対象の監視 | DD-A1〜A7、S1〜S3m（候補をすべて） | 採用した M1〜M4 だけ |
| ログ名の条件 | なし（`resource.type` だけ） | あり（アラートの通知ログが同じ `resource.type` で出るため） |
| M1 の閾値 | `> 0` のみ | 危険 ≧ 20、警告 ≧ 1 |
| M3 の条件 | `resource.type` と `severity` だけ | ログ名と `job_id` を追加 |
| 評価期間 | 10 分 | ログ監視は 5 分、Uptime は 10 分＋No Data 15 分 |
