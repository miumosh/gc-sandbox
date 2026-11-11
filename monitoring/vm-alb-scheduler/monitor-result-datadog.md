# Datadog 監視設定

[monitoring-result.md](monitoring-result.md) で決めた 4 つの監視（M1〜M4）を、Datadog のモニターとして実装するための設定値。

- monitoring-result.md: 何を・どの条件で監視するか（GCP 側のログの条件は Cloud Logging の検索クエリで記載）
- このドキュメント: その条件を Datadog の検索クエリとモニター設定に書き直したもの

> 注意: Datadog への取り込みとモニターは、今回の検証では動かしていない（未検証）。導入時は「5. 導入時の確認手順」で、検索クエリが想定どおりのログに一致するかを確認してから有効化する。

---

## 1. 書き方の方針

既存の Workflows の監視（`status:(error OR critical OR emergency) OR @protopayload.status.code:>0`）と同じ書き方にそろえる。

| 要素 | 書き方 | 意味 |
|---|---|---|
| ログレベル | `status:(error OR critical OR alert OR emergency)` | Datadog がログに付けるログレベル。GCP の `severity` から自動で設定される（ERROR→error、CRITICAL→critical、ALERT→alert、EMERGENCY→emergency、WARNING→warn）。ERROR 以上をまとめて拾う |
| GCP のエラーコード | `@protoPayload.status.code:>0` | 監査ログの失敗時に付くコード（成功時は付かない。権限不足は 7）。ログレベルと OR にして、どちらかで拾う |
| 対象の絞り込み | `@resource.type:...`、`@resource.labels.<ラベル>:...` | GCP のログの項目をそのまま `@` 付きで指定する |
| ワイルドカード | `*` | 例: `vas-web-*` |

- 属性名の大文字・小文字（`@protoPayload` か `@protopayload` か）や、前に `data.` が付くかどうかは、Datadog への取り込み方で変わる。**既存の Workflows の監視で動いている書き方に合わせる**。以下は GCP のログの項目名どおり（`@protoPayload`）で書いている
- **ファセット**: Datadog で、ログの項目を検索・集計に使えるよう登録したもの。Workflows の監視で `@protopayload.status.code:>0` が動いているなら、GCP の標準的な項目は既に使える状態になっている。今回新たに使う項目（`@resource.labels.job_id`、`@httpRequest.status` など）が検索に効かない場合だけ、Log Explorer でログを開き、その項目をクリックして「Create facet」を選ぶ（5 章）

---

## 2. モニター一覧

| ID | モニター名 | タイプ | 判定 | 危険 | 警告 | メンテナンス中 |
|---|---|---|---|---|---|---|
| M1 | `[M1][log] 内部ALB 5xx応答` | Log Monitor | 5 分間の 5xx ログ件数 | ≧ 20 | ≧ 1 | 2 台同時停止なら Downtime |
| M2 | `[M2][metric] VM停止（Uptime途絶）` | Metric Monitor | VM 別の No Data | No Data 15 分 | – | Downtime |
| M3 | `[M3][log] Cloud Schedulerジョブ失敗` | Log Monitor | 5 分間のエラーログ件数 | ≧ 1 | – | 抑止しない |
| M4 | `[M4][log] Compute起動停止の失敗（監査ログ）` | Log Monitor | 5 分間のエラーログ件数 | ≧ 1 | – | 抑止しない |

### 2.1 エラー判定文字列と解説

| ID | 監視 | エラー判定文字列 | 除外文字列 | 解説 |
|---|---|---|---|---|
| M1 | ALB のリクエストログ 5xx 系 | `@resource.type:internal_http_lb_rule @resource.labels.forwarding_rule_name:vas-fr-http @httpRequest.status:>=500` | `-@httpRequest.userAgent:GoogleStackdriverMonitoring*` | ・`@resource.type:internal_http_lb_rule`: 内部 ALB のリクエストログに絞る<br>・`@resource.labels.forwarding_rule_name:vas-fr-http`: 対象の ALB（転送ルール）に絞る。内部 ALB のログにはバックエンドサービス名のラベルが無いため、転送ルール名で絞る<br>・`@httpRequest.status:>=500`: ALB がクライアントに返した HTTP ステータスが 5xx のもの<br>・`status:error` を使わない理由: 5xx でもログレベルが WARNING になるため（検証時の 5xx 174 件すべて WARNING）<br>・除外: GCP の Uptime Check からのアクセスを併用する場合、全台停止時に 5xx を重複して数えるので外す（併用しなければ不要） |
| M2 | Compute Engine の Uptime | –（メトリクス監視: `gcp.gce.instance.uptime` の No Data） | – | ・ログではなく指標で監視する。VM が停止すると uptime 指標が届かなくなるので、VM ごとに「15 分間届かない」ことを検知する<br>・ALB のヘルスチェックログは VM 停止（TERMINATED）では出ないため、VM 停止の検知はこの監視が担う |
| M3 | Cloud Scheduler のジョブの実行ログ | `@resource.type:cloud_scheduler_job @resource.labels.job_id:vas-web-* status:(error OR critical OR alert OR emergency)` | `-@resource.labels.job_id:vas-failure-test` | ・`@resource.type:cloud_scheduler_job`: Scheduler のジョブの実行ログに絞る<br>・`@resource.labels.job_id:vas-web-*`: VM 起動・停止のジョブ（`vas-web-1-start` など 4 つ）に絞る。同じプロジェクトの他のジョブを拾わない<br>・`status:(error OR critical OR alert OR emergency)`: ログレベル ERROR 以上。失敗すると実行結果のログが ERROR になる（検証で確認: `PERMISSION_DENIED`、HTTP 403）。成功時・開始時のログは INFO なので一致しない<br>・`@protoPayload.status.code` を使わない理由: Scheduler の実行ログにはこの項目が無い（エラー内容は `jsonPayload.status` に入る）<br>・除外: 検証用に意図的に失敗させるジョブ。本番では作らない<br>・注意: 起動・停止の処理が受付後に失敗しても、ここでは成功に見える。M4 とセットで使う |
| M4 | Compute Engine の監査ログ | `@resource.type:gce_instance @protoPayload.methodName:(*compute.instances.start OR *compute.instances.stop) @protoPayload.resourceName:*vas-web-* (status:(error OR critical OR alert OR emergency) OR @protoPayload.status.code:>0)` | `-@protoPayload.authenticationInfo.principalEmail:<運用者・CI のアカウント>` | ・`@resource.type:gce_instance`: VM に関するログに絞る<br>・`@protoPayload.methodName:(*compute.instances.start OR *compute.instances.stop)`: VM の起動・停止の操作に絞る。前に `*` を付けるのは、API のバージョンで接頭辞（`v1.`、`beta.`）が変わるため<br>・`@protoPayload.resourceName:*vas-web-*`: 対象の VM に絞る<br>・`status:(...) OR @protoPayload.status.code:>0`: Workflows の監視と同じ考え方。ログレベルが ERROR 以上、またはエラーコードが付いたものを拾う。成功時は NOTICE でエラーコードなし、権限不足では ERROR かつコード 7（検証で確認）<br>・受付後の処理の失敗（リソース不足など）も、処理完了のログが ERROR になるので拾える想定（未再現）<br>・除外: 運用者や CI による手動操作の失敗を通知しない場合だけ設定する |

---

## 3. 各モニターの設定

### 3.1 M1: 内部 ALB 5xx 応答（ALB のリクエストログ）

| 項目 | 設定値 |
|---|---|
| エラー判定文字列 | `@resource.type:internal_http_lb_rule @resource.labels.forwarding_rule_name:vas-fr-http @httpRequest.status:>=500` |
| 除外文字列 | `-@httpRequest.userAgent:GoogleStackdriverMonitoring*`（GCP の Uptime Check を併用する場合） |
| 閾値 | 危険: 5 分間に 20 件以上／警告: 5 分間に 1 件以上 |
| モニタークエリ | `logs("<エラー判定文字列> <除外文字列>").index("*").rollup("count").last("5m") >= 20` |

- **`status:error` は使えない**。ALB のリクエストログは 5xx でも GCP の severity が WARNING（検証時の 5xx 174 件すべて）なので、Datadog の `status` も `warn` になる。HTTP ステータスコードで判定する
- Datadog の GCP 用の処理で、`httpRequest.status` が標準の項目 `@http.status_code` に変換されている場合は、`@http.status_code:>=500` と書く（Log Explorer で確認）
- 閾値の根拠（検証時の実測、2 秒ごとのリクエスト）: 全台停止は約 30 件／分、アプリ停止は 4 件、VM 1 台の停止は 1 件。危険の閾値は本番のリクエスト量で見直す

### 3.2 M2: VM 停止（Compute Engine の Uptime）

| 項目 | 設定値 |
|---|---|
| 監視対象メトリクス | `gcp.gce.instance.uptime` |
| モニタークエリ | `avg(last_10m):avg:gcp.gce.instance.uptime{project_id:miumosh-sb-test01,instance_name:vas-web-*} by {instance_name} < 0` |
| 閾値 | 値では発報しない（`< 0` は常に偽のダミー条件）。**No Data が 15 分続いたら危険** |
| オプション | `notify_no_data: true`、`no_data_timeframe: 15`、`evaluation_delay: 300`（GCP 指標の取り込み遅延の吸収。要調整） |

- ログ監視ではないので、エラー判定文字列は無い。VM が停止すると指標が届かなくなることを検知する

### 3.3 M3: Cloud Scheduler ジョブ失敗（ジョブの実行ログ）

| 項目 | 設定値 |
|---|---|
| エラー判定文字列 | `@resource.type:cloud_scheduler_job @resource.labels.job_id:vas-web-* status:(error OR critical OR alert OR emergency)` |
| 除外文字列 | `-@resource.labels.job_id:vas-failure-test`（検証用に意図的に失敗させるジョブ。本番では作らない） |
| 閾値 | 危険: 5 分間に 1 件以上／警告: なし |
| モニタークエリ | `logs("<エラー判定文字列> <除外文字列>").index("*").rollup("count").last("5m") > 0` |

- 失敗すると、実行結果のログが ERROR になる（検証で確認。`jsonPayload.status: PERMISSION_DENIED`、`httpRequest.status: 403`）。成功時と実行開始時のログは INFO なので、`status:error` で失敗だけに絞れる
- Cloud Monitoring のアラートの通知ログも同じ `resource.type:cloud_scheduler_job` で出るが、ログレベルが ERROR ではないので、この条件には一致しない
- **このログだけでは足りない**。起動・停止の処理が受付後に失敗しても、Scheduler 上は成功（INFO、200）になる。M4 とセットで使う

### 3.4 M4: Compute 起動・停止の失敗（監査ログ）

| 項目 | 設定値 |
|---|---|
| エラー判定文字列 | `@resource.type:gce_instance @protoPayload.methodName:(*compute.instances.start OR *compute.instances.stop) @protoPayload.resourceName:*vas-web-* (status:(error OR critical OR alert OR emergency) OR @protoPayload.status.code:>0)` |
| 除外文字列 | `-@protoPayload.authenticationInfo.principalEmail:<運用者・CI のアカウント>`（Scheduler 以外の手動操作の失敗を通知しない場合。手動操作の失敗も通知したいなら設定しない） |
| 閾値 | 危険: 5 分間に 1 件以上／警告: なし |
| モニタークエリ | `logs("<エラー判定文字列> <除外文字列>").index("*").rollup("count").last("5m") > 0` |

- Workflows の監視と同じく、ログレベルと GCP のエラーコードを OR にしている。正常な起動・停止のログは NOTICE で、`protoPayload.status` は空。権限不足（403）では ERROR になり、`protoPayload.status.code: 7` が付く（検証で確認）
- `methodName` の前に `*` を付けているのは、API のバージョンで接頭辞が変わるため（`v1.compute.instances.start`、`beta.compute.instances.start`）
- 受付後の処理の失敗（リソース不足など）は、処理完了のログが ERROR になる想定（未再現）

---

## 4. Terraform（datadog provider）

検索クエリに `"` や `\` を含めていないので、HCL のエスケープは不要。

```hcl
locals {
  project_id = "miumosh-sb-test01"
  notify     = "@notify" # 通知先に置き換える（例: @slack-ops-alert）
  error_lv   = "status:(error OR critical OR alert OR emergency)"

  q_m1 = "@resource.type:internal_http_lb_rule @resource.labels.forwarding_rule_name:vas-fr-http @httpRequest.status:>=500 -@httpRequest.userAgent:GoogleStackdriverMonitoring*"
  q_m3 = "@resource.type:cloud_scheduler_job @resource.labels.job_id:vas-web-* ${local.error_lv} -@resource.labels.job_id:vas-failure-test"
  q_m4 = "@resource.type:gce_instance @protoPayload.methodName:(*compute.instances.start OR *compute.instances.stop) @protoPayload.resourceName:*vas-web-* (${local.error_lv} OR @protoPayload.status.code:>0)"

  tags = ["service:vm-alb-scheduler", "managed-by:terraform"]
}

resource "datadog_monitor" "m1_ilb_5xx" {
  name    = "[M1][log] 内部ALB 5xx応答"
  type    = "log alert"
  query   = "logs(\"${local.q_m1}\").index(\"*\").rollup(\"count\").last(\"5m\") >= 20"
  message = <<-EOT
    {{#is_alert}}[危険] 内部 ALB（vas-fr-http）が 5 分間に {{value}} 件の 5xx を返しました。全台停止の可能性があります。{{/is_alert}}
    {{#is_warning}}[警告] 内部 ALB（vas-fr-http）が 5xx を返しました（{{value}} 件／5 分）。継続する場合は確認してください。{{/is_warning}}
    {{#is_recovery}}内部 ALB の 5xx が収まりました。{{/is_recovery}}
    ${local.notify}
  EOT

  monitor_thresholds {
    critical = 20
    warning  = 1
  }

  enable_logs_sample = true
  renotify_interval  = 60
  tags               = concat(local.tags, ["monitor:m1"])
}

resource "datadog_monitor" "m2_vm_uptime" {
  name    = "[M2][metric] VM停止（Uptime途絶）"
  type    = "query alert"
  query   = "avg(last_10m):avg:gcp.gce.instance.uptime{project_id:${local.project_id},instance_name:vas-web-*} by {instance_name} < 0"
  message = <<-EOT
    {{#is_no_data}}[危険] VM {{instance_name.name}} の uptime 指標が 15 分間届いていません（VM 停止の可能性）。月次メンテナンス中でないか確認してください。{{/is_no_data}}
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
  query   = "logs(\"${local.q_m3}\").index(\"*\").rollup(\"count\").last(\"5m\") > 0"
  message = <<-EOT
    {{#is_alert}}[危険] Cloud Scheduler の VM 起動・停止ジョブが失敗しました。添付のログでジョブ名（resource.labels.job_id）とエラー（jsonPayload.status）を確認し、対処後に手動で再実行してください。
    gcloud scheduler jobs run <ジョブ名> --location=asia-northeast1{{/is_alert}}
    ${local.notify}
  EOT

  monitor_thresholds {
    critical = 0
  }

  enable_logs_sample = true
  tags               = concat(local.tags, ["monitor:m3"])
}

resource "datadog_monitor" "m4_compute_op_failed" {
  name    = "[M4][log] Compute起動停止の失敗（監査ログ）"
  type    = "log alert"
  query   = "logs(\"${local.q_m4}\").index(\"*\").rollup(\"count\").last(\"5m\") > 0"
  message = <<-EOT
    {{#is_alert}}[危険] Compute Engine の起動・停止が失敗しました。添付のログで対象の VM（protoPayload.resourceName）とエラー（protoPayload.status.message）を確認してください。Scheduler のジョブが成功になっていても、受付後の処理で失敗している場合があります。{{/is_alert}}
    ${local.notify}
  EOT

  monitor_thresholds {
    critical = 0
  }

  enable_logs_sample = true
  tags               = concat(local.tags, ["monitor:m4"])
}
```

- `enable_logs_sample = true` で、通知に一致したログのサンプルが添付される。ジョブ名や VM 名はそこで確認する（ジョブ別・VM 別に通知を分けたい場合は、クエリに `.by("@resource.labels.job_id")` などを追加する。その項目のファセット登録が必要）

### 4.1 月次メンテナンスの Downtime（M1・M2）

```hcl
resource "datadog_downtime_schedule" "monthly_maintenance" {
  scope = "*"

  monitor_identifier {
    monitor_tags = ["monitor:m2"] # 2 台同時停止の運用なら M1 も対象にする
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

---

## 5. 導入時の確認手順

1. Datadog の Log Explorer で、Workflows の監視で使っているログを 1 件開き、属性名の書き方（`@protoPayload` か `@protopayload` か、前に `data.` が付くか）を確認する。違えば、このドキュメントのクエリをそれに合わせる
2. 各監視のエラー判定文字列（除外を含む）を Log Explorer で検索する
   - 過去のログで、正常時に一致しないこと（誤検知しないこと）を確認する
   - 検索が効かない項目があれば、ログを開いてその項目をクリックし「Create facet」を選ぶ（数値の `@httpRequest.status` は「Measure」として作成）
3. モニターを作成し、通知先をテスト用にした状態で、失敗を意図的に起こして発報を確認する
   - M3・M4: Scheduler の SA から VM の権限を外し、ジョブを手動実行する（`gcloud scheduler jobs run`。検証の T5 と同じ）
   - M1・M2: VM を 2 台とも停止する（検証の T2 と同じ）
4. 通知先を本番用に切り替える

---

## 6. 既存サンプル（datadog/monitors.tf）との違い

[datadog/monitors.tf](datadog/monitors.tf) は検証前に作ったサンプルで、このドキュメントとは次の点が違う。

| 項目 | datadog/monitors.tf | このドキュメント |
|---|---|---|
| 対象の監視 | DD-A1〜A7、S1〜S3m（候補をすべて） | 採用した M1〜M4 だけ |
| 属性の書き方 | `@data.` 付き、`@data.severity:ERROR` | Workflows の監視と同じ書き方（`status:(...)`、`@protoPayload...`） |
| M1 の閾値 | `> 0` のみ | 危険 ≧ 20、警告 ≧ 1 |
| M4 の条件 | `severity` だけ | ログレベル OR `protoPayload.status.code:>0` |
| 評価期間 | 10 分 | ログ監視は 5 分、Uptime は 10 分＋No Data 15 分 |
