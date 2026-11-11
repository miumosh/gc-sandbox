# vm-alb-scheduler: 内部 ALB 配下 VM の停止検知 / Cloud Scheduler 起動停止失敗の検知を検証する

> ステータス: **検証完了・環境は削除済み**（2026-11-10 UTC に実施）
> - 検証結果（時系列・遅延の実測値）: [`RESULTS.md`](RESULTS.md)
> - 知見（ログの形式・挙動・注意点）: [`KNOWLEDGE.md`](KNOWLEDGE.md)
> - 監視設計の推奨・月次メンテナンス時の静観/注視: [`monitoring-and-maintenance.md`](monitoring-and-maintenance.md)
> - 採用した監視 4 つの Datadog 設計（メトリクス詳細・ログ監視条件）: [`monitoring-result.md`](monitoring-result.md)
> - Datadog のサンプル（未適用）: [`datadog/README.md`](datadog/README.md)
> - 取得したログ（実体は Git 管理外）と取得スクリプト: [`logs/README.md`](logs/README.md)
> - 作業と監視結果の時系列表: [`test-history.md`](test-history.md)

## 0. 結論（要約）

| 確認したいこと | 結果 |
|---|---|
| 内部 ALB 配下の VM 停止を **ログから** 検知できるか | **ヘルスチェックログでは、VM 停止を検知できない**（停止した VM はヘルスチェック対象から外れ、遷移ログが出ない）。検知できるのは「VM は動いているがアプリが応答しない」場合だけ（約 23 秒）。VM 停止をログで検知するには **監査ログの stop 完了（A7、約 1 分）** を使う |
| ログ以外の方法 | **A6: 内部 ALB のバックエンド別 `backend_request_count` の途絶**（ALB の観点。VM 停止とアプリ停止の両方を約 6〜7 分で検知。常時トラフィックが前提）、**A5: `instance/uptime` の途絶**（約 8.7 分）、**A4: プライベート Uptime Check**（全台停止のみ。約 2 分） |
| Scheduler の起動・停止の失敗をログで検知できるか | ◯ **S1**（`AttemptFinished` かつ ERROR、約 35〜49 秒）、**S3**（監査ログの ERROR、約 20〜49 秒） |
| Scheduler の起動・停止の失敗を指標で検知できるか | ◯ **S2**（ログベース指標、`job_id` ごと、約 3.4〜4 分）。**Scheduler の組み込み指標は存在しない** |
| Terraform で管理できるか | ◯ すべて Terraform で管理した（前提作業として、Monitoring サービスエージェントの作成だけ gcloud で実施） |

## 1. ディレクトリ構成

```
monitoring/vm-alb-scheduler/
├── README.md / RESULTS.md / KNOWLEDGE.md
├── .gitignore
├── versions.tf / variables.tf / apis.tf
├── network.tf        # VPC、サブネット 3 つ、ファイアウォール
├── compute.tf        # バックエンド VM ×2、IG ×2、試験クライアント（VIP へ 2 秒ごとにリクエスト）
├── lb.tf             # リージョン内部 ALB（VIP は固定の内部 IP。グローバルアクセス有効）
├── scheduler.tf      # Cloud Scheduler（起動停止 ×4、失敗再現 ×1）
├── monitoring.tf     # ログベース指標 ×3、アラート ×10、プライベート Uptime Check
├── outputs.tf
├── terraform.tfvars.example
└── datadog/          # Datadog 監視のサンプル（別 state。今回は未適用）
```

## 2. 構成

```
 VPC: vas-vpc (asia-northeast1)
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ NW 用サブネット 10.10.0.0/24                                             │
 │   ● 内部 ALB のフロントエンド VIP 10.10.0.10（固定プライベート IP）◄─┐    │
 │   ● vas-client（2 秒ごとに curl で VIP へリクエスト）────────────────┤    │
 │                 プライベート Uptime Check [A4]（6 拠点 / 60 秒）────┘    │
 │                   ※ 転送ルールの allow_global_access=true が必須        │
 │ プロキシ専用サブネット 10.10.64.0/23 (REGIONAL_MANAGED_PROXY)             │
 │   ● リージョン内部 ALB（Envoy）  リクエストログ [A2]、指標 [A6]           │
 │         │ プロキシ専用サブネット → tcp:80                                │
 │         │ ヘルスチェック（5 秒間隔 / 2 回失敗で UNHEALTHY）、ログ [A1][A3]│
 │ アプリ用サブネット 10.10.1.0/24                                          │
 │   ● vas-web-1 (zone a) / vas-web-2 (zone b)  非マネージド IG ×2          │
 │     外部 IP なし。python3 http.server :80。uptime 指標 [A5]              │
 └─────────▲────────────────────────────────────────────────────────────────┘
           │ POST compute.instances.start / stop（OAuth。VM 単位の最小権限カスタムロール）
 ┌─────────┴────────────────────┐
 │ Cloud Scheduler              │  実行ログ [S1][S2]
 │  web-1/2 の start / stop     │  Compute 監査ログ [S3]（失敗）、[A7]（停止完了）
 │  failure-test                │
 └──────────────────────────────┘
```

### 2.1 サブネットとファイアウォール

| サブネット | CIDR | 用途 |
|---|---|---|
| `vas-nw-subnet` | `10.10.0.0/24` | VIP `10.10.0.10`、試験クライアント |
| `vas-proxy-only-subnet` | `10.10.64.0/23` | `REGIONAL_MANAGED_PROXY` / ACTIVE |
| `vas-app-subnet` | `10.10.1.0/24` | バックエンド VM ×2 |

| ファイアウォール | 送信元 | 宛先 | ポート |
|---|---|---|---|
| `vas-allow-lb-hc` | `35.191.0.0/16`, `130.211.0.0/22` | `vas-web` | tcp:80 |
| `vas-allow-proxy-only` | `10.10.64.0/23` | `vas-web` | tcp:80 |
| `vas-allow-iap-ssh` | `35.235.240.0/20` | `vas-web`, `vas-client` | tcp:22 |

クライアントから VIP への通信には、ファイアウォールルールは不要（実際に確認した）。

### 2.2 主な変数

| 変数 | 既定値 | 用途 |
|---|---|---|
| `project_id` / `notification_email` | （必須） | `terraform.tfvars` に書く（Git 管理外） |
| `nw_subnet_cidr` / `ilb_vip_address` / `proxy_only_subnet_cidr` / `app_subnet_cidr` | 上表のとおり | |
| `start_schedule` / `stop_schedule` | `0 9 * * 1-5` / `0 19 * * 1-5`（Asia/Tokyo） | |
| `scheduler_paused` | `false` | |
| `grant_scheduler_permission` | `true` | `false` で 403 を再現する |
| `enable_failure_test_job` | `true` | 存在しない VM への start ジョブ（**実際は 403 になる**） |
| `enable_test_client` / `client_traffic_enabled` | `true` / `true` | 試験クライアントと常時トラフィック |
| `enable_uptime_check` | `true` | プライベート Uptime Check（あわせて `allow_global_access` も有効になる） |
| `enable_gcp_alert_policies` | `true` | Cloud Monitoring のアラート一式 |

## 3. 検知方式（実装と検証結果）

### 3.1 内部 ALB 配下の VM 停止とアプリ停止

| ID | 種別 | ソースと条件 | VM 停止（1 台） | アプリ停止（1 台） | 全台停止 | 実測の遅延 |
|---|---|---|---|---|---|---|
| A1 | ログ | ヘルスチェックログ `healthState=UNHEALTHY` かつ `previousHealthState=HEALTHY`（`resource.type=gce_instance_group`） | **×** | ◯ | （×）※ | 約 23 秒 |
| A2 | ログ | 内部 ALB のログ `forwarding_rule_name=vas-fr-http` かつ `httpRequest.status>=500` | × | △（停止直後の約 8 秒だけ 503） | ◯ | （参考値なし） |
| A3 | 指標 | A1 のログから作ったログベース指標（`resource.type=global`）> 0 | **×** | ◯ | （×）※ | 約 3.4〜3.7 分 |
| A4 | 指標 | プライベート Uptime Check（`servicedirectory_service`） | × | × | ◯ | 約 2 分 10 秒 |
| A5 | 指標 | `compute.googleapis.com/instance/uptime` が 3 分間途絶（`instance_name` ごと） | ◯ | × | ◯ | 約 8.7 分 |
| A6 | 指標 | `loadbalancing…/internal/backend_request_count` が 3 分間途絶（`backend_name` ごと） | ◯ | ◯ | ◯ | 約 5.9〜6.9 分 |
| A7 | ログ | 監査ログ `compute.instances.stop` かつ `operation.last=true` | ◯ | × | ◯ | 約 1 分 16 秒 |

※ VM 停止による全台停止の場合。アプリ停止による全台停止なら A1 / A3 も反応する。

### 3.2 Cloud Scheduler の起動・停止の失敗

| ID | 種別 | ソースと条件 | API の失敗（403 など） | オペレーションの失敗 | 実測の遅延 |
|---|---|---|---|---|---|
| S1 | ログ | `cloud_scheduler_job` の `AttemptFinished` かつ `severity>=ERROR`（`job_id` と `status` を抽出） | ◯ | × | 約 35〜49 秒 |
| S2 | 指標 | S1 のログから作ったログベース指標（`cloud_scheduler_job`、`job_id` ごと）> 0 | ◯ | × | 約 3.4〜4 分 |
| S3 | ログ | 監査ログ `compute.instances.(start\|stop)` かつ `severity>=ERROR` | ◯（403 も記録される） | ◯（想定。再現はしていない） | 約 20〜49 秒 |
| S4 | 指標 | Cloud Scheduler の組み込み指標 | **存在しない** | – | – |

ログフィルタの実物と、各ログの形式は [`KNOWLEDGE.md`](KNOWLEDGE.md) を参照。

## 4. 検証シナリオと結果

| # | 操作 | 発報したもの | 発報しなかったもの | 主な発見 |
|---|---|---|---|---|
| T0 | Apply 直後 | A1（修正前のフィルタ） | – | 起動時の `UNKNOWN→TIMEOUT` で誤検知した → `previousHealthState` 条件で解消 |
| T1 | Scheduler で web-1 を停止 | A7, A6, A5 | **A1, A3**, A2, A4 | VM 停止ではヘルスチェックログが出ない |
| T1b | web-1 / web-2 のアプリだけ停止 | A1, A3, A6,（A2 は既存インシデントにまとめられた） | A5, A4 | A1 は約 23 秒。同じラベルのインシデントが開いていると新たに発報しない |
| T2 | 続けて web-2 も停止（2 台とも停止） | A4, A2,（A5 / A6） | – | 503 の `proxyStatus` は出たり出なかったりする |
| T3 | 2 台とも起動 | （A4 が回復） | A1（新しいフィルタ） | 起動指示から約 50 秒で HEALTHY |
| T4 | 失敗再現ジョブ（存在しない VM） | S3, S1, S2 | – | 404 ではなく **403** になった |
| T5 | IAM を外して stop | S1, S3, S2 | – | IAM の変更は約 90 秒以内に反映 |
| T6 | 停止済みの VM に stop | A7 | S1, S3 | 冪等で 200。no-op でも A7 は発報する |
| T7 | オペレーションの失敗 | – | – | 再現する手段がなく、未実施 |

詳細な時系列は [`RESULTS.md`](RESULTS.md) を参照。

## 5. 手順（再現する場合）

### 5.1 前提

- 実行者に Owner 相当の権限があること
- Terraform 1.6 以上（検証は 1.15.5）、google provider 7.x（検証は 7.46.2）
- Monitoring サービスエージェントを作成しておく（プライベート Uptime Check の IAM 付与に必要）

```bash
gcloud beta services identity create --service=monitoring.googleapis.com --project=<PROJECT>
```

### 5.2 Apply

```bash
gcloud auth login
# ADC を使う場合は gcloud auth application-default login。使わない場合は次の行
export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)   # 約 1 時間で失効する
cd monitoring/vm-alb-scheduler
cp terraform.tfvars.example terraform.tfvars   # project_id / notification_email を記入
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### 5.3 検証操作の例

```bash
R=asia-northeast1
gcloud scheduler jobs run vas-web-1-stop   --location=$R   # T1
gcloud scheduler jobs run vas-failure-test --location=$R   # T4
terraform apply -var grant_scheduler_permission=false      # T5 の準備（終わったら戻す）
terraform output log_filters                               # Logs Explorer 用のフィルタ
# インシデントの一覧（Monitoring API）
curl -s -G -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://monitoring.googleapis.com/v3/projects/<PROJECT>/alerts" --data-urlencode "orderBy=open_time desc"
```

アプリだけを止める場合は IAP SSH で `sudo systemctl stop simple-web`（鍵にパスフレーズがあるなら `--ssh-key-file` で使い捨て鍵を指定する）。

### 5.4 後片付け

```bash
terraform destroy
```

- 有効化した API は残る（`disable_on_destroy = false`）
- カスタムロールは、削除後 7 日間は同じ ID で作り直せない
- 試験クライアントは、作成中ずっとトラフィックを流し続ける（LB のログが増える）

## 6. 運用に向けた検討事項

- **計画停止のノイズ**: 毎日 19 時の Scheduler 停止で A5 / A6 / A7 は必ず発報する。停止時間帯のスヌーズ、A7 を `principalEmail` で分けて Scheduler の SA を除外する、A5 / A6 を営業時間だけ有効にする、などの対策が必要
- **ログベースアラートのまとめ方**: ラベル抽出がないと、すべての事象が 1 つのインシデントにまとめられ、2 回目以降は通知されない。`label_extractors` で識別子を抽出する
- **A6 の前提**: 常時トラフィックが必要。トラフィックがない時間帯は誤検知するので、Uptime Check と組み合わせて使う
- **Datadog に移す場合**: ログベース指標（`gcp.logging.user.*`）を GCP インテグレーションで取り込めば、ログ転送なしでも A3 / S2 / S3m 相当を作れる。知見を反映済みのサンプルは `datadog/`

## 7. 費用の目安（東京、概算）

| 項目 | 目安 |
|---|---|
| e2-micro ×3 | 常時起動で 1 台あたり約 $8/月 |
| 内部 ALB（転送ルール + プロキシ） | 約 $18〜25/月 |
| Cloud Scheduler | 3 ジョブまで無料。それ以降は 1 ジョブ $0.10/月 |
| Logging / Monitoring / Uptime Check | 検証規模なら無料枠に収まる |

今回の検証（約 1.5 時間）の費用は、1 ドル未満の見込み。

## 8. シークレットの扱い

- `.gitignore` をルート、`monitoring/`、`monitoring/vm-alb-scheduler/`、`monitoring/vm-alb-scheduler/datadog/` に置いた
- 除外対象: `*.tfstate*`、`.terraform/`、`*.tfvars`（`*.tfvars.example` は除外しない）、`*.tfplan`、SA キー、`.env*`、`*.pem`、`*.key`
- `notification_email` は sensitive 指定にし、Git 管理外の `terraform.tfvars` にだけ書く
- SA キーは発行しない（Scheduler は OAuth、VM はアタッチした SA）
- `.terraform.lock.hcl` はコミットする
