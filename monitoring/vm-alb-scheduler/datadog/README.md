# datadog: vm-alb-scheduler 用 Datadog 監視サンプル

親ディレクトリ（`../`）で作った GCP リソースを Datadog で監視するための Terraform サンプル。state は親とは別に持つ。

> ステータス: **未適用のサンプル**（`terraform validate` 済み、datadog provider 4.30.0）
> GCP 側の検証（`../RESULTS.md`）で分かったこと（ログの形式、ラベル名、検知できる事象とできない事象）は反映済み。Datadog 上の指標名やタグへの変換は **未確認**。

## 1. データの取り込み方

```
GCP Cloud Monitoring 指標 ──(GCP インテグレーション / STS)──► Datadog Metrics ──► 指標モニター
  ├ gcp.logging.user.vas_*              ← 親側で作ったログベース指標
  ├ gcp.monitoring.uptime_check.*       ← プライベート Uptime Check
  ├ gcp.gce.instance.uptime
  └ gcp.loadbalancing.https.internal.*

GCP Cloud Logging ──(任意: シンク → Pub/Sub → Dataflow → Datadog)──► Datadog Logs ──► ログモニター
```

| 方式 | 必要なもの | 費用 | 使えるモニター |
|---|---|---|---|
| **指標のみ**（既定） | GCP インテグレーション | Datadog 側の費用のみ | DD-A3 / A4 / A5 / A6 / A7 / S2 / S3m |
| **指標 + ログ** | 上記に加えて `enable_log_forwarding=true` | Dataflow 約 $50〜70/月、Datadog のログ取り込み費用 | 上記に加えて DD-A1 / A2 / S1 / S3 |

**推奨:** まず「指標のみ」で始める。ログを起点にした検知は、GCP 側のログベース指標（A3 / S2 / S3m）を取り込めば実現できる。

## 2. リソース

| ファイル | 内容 |
|---|---|
| `gcp_integration.tf` | Datadog 連携用の SA（monitoring.viewer / compute.viewer / cloudasset.viewer / browser）、`datadog_integration_gcp_sts`、Datadog の委任 SA への `serviceAccountTokenCreator` 付与。**`automute=false`**（停止した VM のモニターを自動でミュートしない。ミュートされると VM 停止の検知が成り立たないため） |
| `log_forwarding.tf` | （`enable_log_forwarding=true` のときのみ）ログシンク（監視に必要なログだけ）、Pub/Sub（本線と DLQ）、Secret Manager（API キーの入れ物）、Dataflow 用の SA・一時バケット・サブネット `10.10.2.0/24`・Cloud NAT・ファイアウォール、Dataflow ジョブ（`Cloud_PubSub_to_Datadog`） |
| `monitors.tf` | Datadog モニター（下表） |

## 3. モニター一覧（GCP 側の ID との対応）

| DD の ID | GCP 側 | 種別 | クエリ（要旨） | VM 停止 | アプリ停止 | 全台停止 | 前提 |
|---|---|---|---|---|---|---|---|
| DD-A1 | A1 | log | `healthState:UNHEALTHY` かつ `previousHealthState:HEALTHY` | **×** | ◯ | – | ログ転送 |
| DD-A2 | A2 | log | `resource.type:internal_http_lb_rule` かつ `forwarding_rule_name` かつ `httpRequest.status:>=500` | × | △ | ◯ | ログ転送 |
| DD-A3 | A3 | metric | `sum:gcp.logging.user.vas_hc_unhealthy_count > 0` | **×** | ◯ | – | |
| DD-A4 | A4 | metric | `max:gcp.monitoring.uptime_check.check_passed{check_id} < 1` | × | × | ◯ | 親側の Uptime Check |
| DD-A5 | A5 | metric | `gcp.gce.instance.uptime` by `instance_name` が **データなし** | ◯ | × | ◯ | |
| DD-A6 | （参考） | metric | `gcp.loadbalancing.https.internal.request_count{forwarding_rule_name,response_code_class:500} > 0` | × | △ | ◯ | |
| DD-A7 | A6 | metric | `gcp.loadbalancing.https.internal.backend_request_count{forwarding_rule_name}` by `backend_name` が **データなし** | ◯ | ◯ | ◯ | 常時トラフィック |
| DD-S1 | S1 | log | `resource.type:cloud_scheduler_job` かつ `severity:ERROR` | – | – | – | ログ転送 |
| DD-S2 | S2 | metric | `sum:gcp.logging.user.vas_scheduler_failed_count by {job_id} > 0` | – | – | – | |
| DD-S3 | S3 | log | `methodName:(v1.compute.instances.start OR …stop)` かつ `severity:ERROR` | – | – | – | ログ転送 |
| DD-S3m | S3 | metric | `sum:gcp.logging.user.vas_compute_op_failed_count > 0` | – | – | – | |

GCP 側の A7（監査ログの stop 完了）に相当するモニターは、ログ転送を有効にすれば `@data.protoPayload.methodName:v1.compute.instances.stop @data.operation.last:true` で作れる（サンプルには含めていない）。

## 4. GCP 側の検証で分かり、サンプルに反映したこと

| 項目 | 内容 |
|---|---|
| VM 停止とヘルスチェックログ | 停止した VM の UNHEALTHY 遷移ログは **出ない**。DD-A1 / A3 は「アプリ停止」専用。VM 停止は DD-A5 / A7 で検知する |
| 起動時の誤検知 | `previousHealthState:HEALTHY` の条件がないと、起動のたびに UNHEALTHY のログに反応する |
| 内部 ALB のログ / 指標のラベル | `backend_service_name` は **ない**。使えるのは `forwarding_rule_name` / `backend_target_name` / `backend_name` |
| 内部 ALB のエラーの理由 | `statusDetails` は **ない**。`proxyStatus` は毎回は出ないので、`httpRequest.status>=500` で判定する |
| ヘルスチェックのログベース指標 | GCP では `resource.type=global`。Datadog では `project_id` タグだけになる想定（推測） |
| Scheduler の組み込み指標 | **存在しない**。`gcp.cloudscheduler.*` は使えないので、ログベース指標（DD-S2）を使う |
| 存在しない VM を指定したジョブ | 404 ではなく 403 になる |

## 5. 適用する場合の要確認事項

| # | 内容 | 確認・対応 |
|---|---|---|
| D1 | 指標の取り込み遅延 | GCP インテグレーションは数分おきに取得するため、GCP のアラートより 5〜15 分程度遅れる想定。実測すること |
| D2 | `gcp.logging.user.<name>` という名前になるか、`job_id` タグが付くか | Metrics Explorer で確認する |
| D3 | `gcp.gce.instance.uptime` に `instance_name` タグがあるか | なければ `instance-id` などに変える |
| D4 | `gcp.loadbalancing.https.internal.*` の名前と、`forwarding_rule_name` / `backend_name` タグ | Metrics Explorer で確認する |
| D5 | ログ転送時の属性のパス（`@data.…`） | `includePubsubMessage=true` で送ると、`data` の下に LogEntry が入る想定 |
| D6 | ログモニターで属性を検索するのにファセットが要るか | 必要なら Datadog の画面で作る（Terraform では管理できない） |
| D7 | 手動で設定した GCP 連携と二重登録になる | すでに連携しているなら `enable_gcp_integration=false` にする |
| D8 | 計画停止で DD-A5 / A7 が発報する | `datadog_downtime_schedule` を停止スケジュールに合わせて設定する |
| D9 | DD-A7 は常時トラフィックが前提 | トラフィックがない時間帯は誤検知する。Synthetics の Private Location と組み合わせることも検討する |

## 6. 手順

```bash
cd monitoring/vm-alb-scheduler/datadog
export DD_API_KEY=xxxxx   # ファイルには書かない
export DD_APP_KEY=xxxxx
cp terraform.tfvars.example terraform.tfvars
#   project_id / datadog_site / notify / uptime_check_id / forwarding_rule_name を記入
#   （値は親ディレクトリの `terraform output datadog_inputs` から）
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### ログ転送を有効にする場合（任意）

```bash
terraform apply -var enable_log_forwarding=true \
  -target=google_project_service.lf -target=google_secret_manager_secret.dd_api_key
printf %s "$DD_API_KEY" | gcloud secrets versions add vas-datadog-api-key --data-file=-
terraform apply -var enable_log_forwarding=true
```

## 7. 後片付け

```bash
terraform destroy   # 親ディレクトリより先に実行する
```
