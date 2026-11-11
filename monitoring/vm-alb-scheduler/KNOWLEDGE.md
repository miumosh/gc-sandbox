# ナレッジ集（vm-alb-scheduler 検証で得た知見）

この検証（`RESULTS.md`）で実際に確認できた挙動、ログの形式、Terraform の注意点をまとめる。「（推測）」と付けたもの以外は、すべて実環境で確認した事実。

---

## 1. リージョン内部 Application Load Balancer

### 1.1 構成時の注意

| 項目 | 内容 |
|---|---|
| プロキシ専用サブネット | `purpose = "REGIONAL_MANAGED_PROXY"`、`role = "ACTIVE"`。リージョン × VPC ごとに ACTIVE は 1 つだけ。転送ルールより **先に** 作っておく必要がある（`depends_on` で順序を保証） |
| VIP | `google_compute_address`（`address_type = "INTERNAL"`、`subnetwork` = NW 用サブネット、`address` に固定 IP）を、転送ルールの `ip_address` に指定する |
| ファイアウォール | バックエンド側で、①ヘルスチェック元（`35.191.0.0/16`, `130.211.0.0/22`）と ②プロキシ専用サブネットの CIDR からの通信を許可する。**クライアントから VIP（Envoy）への通信にはファイアウォールルールが要らない**（NW 用サブネットのクライアントから、ルールを追加せずに疎通できた） |
| グローバルアクセス | 既定では同じリージョンのクライアントしか受け付けない。**プライベート Uptime Check は他リージョン扱いになるため、`allow_global_access = true` が必要**（ないと 6 拠点すべてで失敗した） |
| `allow_global_access` の変更 | 転送ルールが **作り直し** になる（Terraform で `forces replacement`）。その間 VIP は短時間停止する |
| リソースの種類 | すべてリージョン版を使う（`google_compute_region_health_check` / `region_backend_service` / `region_url_map` / `region_target_http_proxy`）。`load_balancing_scheme = "INTERNAL_MANAGED"` |

### 1.2 リクエストログ（`resource.type="internal_http_lb_rule"`）

ログを出すにはバックエンドサービスの `log_config { enable = true, sample_rate = 1.0 }` が必要。

**リソースラベル**（`backend_service_name` という名前のラベルは **ない**）:

```
backend_name          vas-ig-web-1        ← インスタンスグループ名。全台停止時は ""
backend_scope         asia-northeast1-a   ← 全台停止時は "UNKNOWN"
backend_scope_type    ZONE                ← 全台停止時は "UNKNOWN"
backend_target_name   vas-bes             ← バックエンドサービス名
backend_target_type   BACKEND_SERVICE
backend_type          INSTANCE_GROUP      ← 全台停止時は "UNKNOWN"
forwarding_rule_name  vas-fr-http
matched_url_path_rule UNMATCHED
network_name, project_id, region, target_proxy_name, url_map_name
```

**jsonPayload**: 外部 ALB と違って `statusDetails` がない。エラーの理由は `proxyStatus` に入る。

| 状況 | httpRequest.status | jsonPayload.proxyStatus | backend_name |
|---|---|---|---|
| 正常 | 200 | なし | IG 名 |
| 全台停止（正常なバックエンドがない） | 503 | `error="destination_unavailable"; details="failed_to_pick_backend"` … **ただし空のことがある**（同じ全台停止中に、前半は空で後半は値あり） | `""` |
| アプリ停止の直後（HC が UNHEALTHY と判定する前の約 8 秒間） | 503 | `error="connection_refused"; details="failed_to_connect_to_backend"` | 対象の IG 名 |
| **VM 停止のシャットダウン中**（アプリが先に止まった場合。2 回中 1 回で 1 件発生） | 503 | 同上 | 対象の IG 名 |
| VM のシャットダウン中にクライアントがタイムアウト | なし | `error="connection_terminated"; details="client_disconnected_before_any_response"` | 対象の IG 名 |

→ **5xx の検知には `httpRequest.status>=500` を使う**。`proxyStatus` はいつも出るとは限らないので、条件にしない。

**ハマりどころ**: Cloud Monitoring のアラートが開いたときやクローズしたときのイベントログ（`logName=…/logs/monitoring.googleapis.com%2FViolationOpenEventv1` など）も、**同じ `resource.type="internal_http_lb_rule"` で記録される**。`httpRequest` がないので、`resource.type` だけで集計すると「status が空のログ」が混じる。条件に `httpRequest.status` を入れるか、`logName` で絞ること。

### 1.3 LB の指標（`loadbalancing.googleapis.com/https/internal/*`、リソースは `internal_http_lb_rule`）

```
backend_latencies / backend_request_bytes_count / backend_request_count / backend_response_bytes_count
request_bytes_count / request_count / response_bytes_count / total_latencies
指標ラベル: response_code, response_code_class（+ protocol, cache_result）
リソースラベル: backend_name, forwarding_rule_name など（ログと同じ）
```

- バックエンドのヘルス状態を表す指標は **ない**
- `backend_request_count` を `resource.label.backend_name` ごとに集計し、**データが途絶えたら発報**（`condition_absent`）すれば、「ALB から見て、そのバックエンドに振り分けられなくなった」ことを検知できる。VM 停止とアプリ停止の両方に反応する（A6）
  - 前提: 常にトラフィックがあること（この検証では試験クライアントが 2 秒ごとに送信）。夜間などトラフィックがない時間帯は誤検知する
  - `backend_name=""`（全台停止時の 503）の時系列を除くため、`resource.label.backend_name=monitoring.regex.full_match(".+")` で絞った

---

## 2. ヘルスチェックログ

### 2.1 出し方と形式

- `google_compute_region_health_check`（グローバル版でも同じ）の `log_config { enable = true }` で出力される
- **状態が遷移したときだけ** 出力される（毎回のプローブ結果は出ない）
- `logName = projects/<P>/logs/compute.googleapis.com%2Fhealthchecks`
- **`resource.type = "gce_instance_group"`**。ラベルは `instance_group_id`、`instance_group_name`、`location`、`project_id`
- severity は INFO

```json
"jsonPayload": {
  "healthCheckProbeResult": {
    "healthState": "UNHEALTHY",              // HEALTHY / UNHEALTHY
    "previousHealthState": "HEALTHY",
    "detailedHealthState": "TIMEOUT",        // HEALTHY / TIMEOUT / UNKNOWN など
    "previousDetailedHealthState": "HEALTHY",
    "ipAddress": "10.10.1.2", "targetIp": "10.10.1.2", "targetPort": 80,
    "probeSourceIp": "35.191.235.172",
    "probeResultText": "HTTP response: , Error: Connection refused",
    "healthCheckProtocol": "HTTP", "probeRequest": "/",
    "responseLatency": "0.000809s", "connectLatency": "...", "probeCompletionTimestamp": "..."
  }
}
```

### 2.2 重要な挙動

1. **VM を停止（TERMINATED）しても、UNHEALTHY 遷移のログは出ない**。停止した VM はヘルスチェックの対象から外れ、`gcloud compute backend-services get-health` の結果からも消える。そのため、**Scheduler による VM 停止はヘルスチェックログでは検知できない**
2. **VM が動いていてアプリが応答しない** 場合（ファイアウォール削除などでヘルスチェックが届かない場合も同じ。destroy 時に確認）は、約 10 秒（間隔 5 秒 × しきい値 2 回）で `HEALTHY→UNHEALTHY(TIMEOUT)` のログが出る
3. **起動時** は `UNHEALTHY(UNKNOWN)→UNHEALTHY(TIMEOUT)` のように、`healthState` が変わらず詳細状態だけが変わってもログが出る。`healthState="UNHEALTHY"` だけで絞ると、**起動のたびに誤検知する**
   → **`previousHealthState="HEALTHY"` の条件を加え、HEALTHY から UNHEALTHY への遷移だけを拾う**
4. 起動後 HEALTHY になるまでの時間: start の指示から約 45〜50 秒（e2-micro / Debian 12 / python http.server の場合）

### 2.3 ログベース指標にしたときの注意

- `gce_instance_group` は **Cloud Monitoring のリソースタイプとして存在しない**（`monitoredResourceDescriptors/gce_instance_group` は 404）
- そのため、ヘルスチェックログから作ったログベース指標は **`resource.type="global"`** として記録される（指標の記述子の `monitoredResourceTypes` も `["global"]`）
- 指標の条件フィルタは `metric.type="logging.googleapis.com/user/<name>" AND resource.type="global"` とする。`resource.type="gce_instance_group"` と書くと `The resource name does not represent a known descriptor` エラーになる
- 一方、Scheduler のログから作ったログベース指標は `cloud_scheduler_job` リソースになる（Monitoring にこのリソースタイプが存在するため）

---

## 3. Cloud Scheduler による VM の起動・停止

### 3.1 実装方式

- Cloud Functions を使わず、HTTP ターゲットで **Compute Engine API を直接呼ぶ**:
  `POST https://compute.googleapis.com/compute/v1/projects/<P>/zones/<Z>/instances/<NAME>/{start|stop}`
- `oauth_token { service_account_email, scope = "https://www.googleapis.com/auth/cloud-platform" }` で認証する。リクエストボディは不要
- 権限: カスタムロール（`compute.instances.start` / `compute.instances.stop` のみ）を、**`google_compute_instance_iam_member` で VM 単位に付与** する。このとおり動いた
- IAM を外したり戻したりした変更は、約 90 秒で反映されていた（外して 90 秒後の実行は 403 になった）
- `retry_count = 0` にすると、1 回目の失敗がそのまま ERROR ログになる

### 3.2 Scheduler のログ（`resource.type="cloud_scheduler_job"`）

- ラベル: `job_id`、`location`、`project_id`
- 1 回の実行で `AttemptStarted`（INFO）と `AttemptFinished`（成功なら INFO、失敗なら **ERROR**）の 2 件が出る

```json
// 失敗の例
"severity": "ERROR",
"jsonPayload": {
  "@type": "type.googleapis.com/google.cloud.scheduler.logging.AttemptFinished",
  "status": "PERMISSION_DENIED",
  "debugInfo": "URL_ERROR-ERROR_OTHER. Original HTTP response code number = 403",
  "jobName": "projects/<P>/locations/asia-northeast1/jobs/vas-web-2-stop",
  "targetType": "HTTP",
  "url": "https://compute.googleapis.com/compute/v1/.../instances/vas-web-2/stop"
},
"httpRequest": { "status": 403 }
```

- 成功時は `httpRequest.status=200` だけで、`status` はない
- 実行してから `AttemptFinished` が出るまでは約 5〜8 秒

### 3.3 Scheduler の「成功」が意味すること

- **Scheduler の成功は、API がオペレーションを受け付けたこと（HTTP 200）しか意味しない**。VM が実際に止まったか、起動したかは保証しない
- stop を受け付けてから TERMINATED になるまでは約 47〜50 秒（監査ログの `operation.first` から `operation.last` まで）
- **すでに停止している VM への stop も HTTP 200**（冪等）。オペレーションは約 0.5 秒で完了する

### 3.4 存在しない VM を指定したとき

- VM 単位でしか権限を持たない SA で、存在しない VM に start を送ると、**404 ではなく 403 PERMISSION_DENIED** になる（存在確認より先に権限チェックで拒否されるため）
- 404 を再現したい場合は、SA にプロジェクト単位の権限が必要（推測）

### 3.5 組み込み指標

- **Cloud Scheduler の組み込み指標（`cloudscheduler.googleapis.com/*`）は存在しない**（Monitoring API の metricDescriptors を前方一致で検索して 0 件）
- 指標で監視したい場合は、ログベース指標（`AttemptFinished` かつ `severity>=ERROR`、`job_id` ラベル付き）を使う

---

## 4. Compute Engine の監査ログ（Admin Activity）

- `logName = projects/<P>/logs/cloudaudit.googleapis.com%2Factivity`、`resource.type = "gce_instance"`
- `protoPayload.methodName` は `v1.compute.instances.stop` / `v1.compute.instances.start`
- 長く掛かる操作は `operation.first=true`（受付）と `operation.last=true`（完了）の **2 件** が出る。severity は NOTICE
- **API が 403 で拒否した呼び出しも、severity=ERROR で記録される**。このため `severity>=ERROR` のフィルタ（S3）は、「オペレーション自体の失敗」だけでなく「権限不足による拒否」にも反応する
- `protoPayload.authenticationInfo.principalEmail` に実行した主体（`vas-scheduler@…`）が入るので、計画停止（Scheduler）か手動停止かを区別できる
- 停止の完了は `methodName=~"compute\.instances\.stop$" AND operation.last=true` で検知できる（A7）。停止完了から約 26 秒で発報した。**no-op の stop（すでに停止中）でも発報する**

---

## 5. Cloud Monitoring アラートポリシーの挙動

### 5.1 指標の条件（condition_threshold / condition_absent）

- **フィルタに `resource.type` の指定が必須**。ないと 400 エラー: `must specify a restriction on "resource.type" in the filter`
- 指標ごとのリソースタイプ:
  - `logging.googleapis.com/user/<ヘルスチェックログ由来>` → `global`
  - `logging.googleapis.com/user/<Scheduler ログ由来>` → `cloud_scheduler_job`
  - `monitoring.googleapis.com/uptime_check/check_passed`（プライベート） → `servicedirectory_service`
  - `compute.googleapis.com/instance/uptime` → `gce_instance`（指標ラベル `instance_name` あり）
  - `loadbalancing.googleapis.com/https/internal/*` → `internal_http_lb_rule`
- ログベース指標（DELTA、INT64）の、ALIGN_SUM でしきい値 > 0 とする条件: ログ発生から 3.4〜4 分で発報し、約 1 分で自動回復した
- `condition_absent`（duration 180s）: データが途絶えてから発報まで 6〜9 分かかった。**ポリシーを作る前からすでに途絶えていた時系列** も、作成後の評価で発報した

### 5.2 ログベースアラート（condition_matched_log）

- `notification_rate_limit` が必須
- 発報までの遅延は、ログの記録から約 13〜45 秒
- **インシデントは「ポリシー × 抽出ラベル（`label_extractors`）の値の組」ごとに 1 つ**:
  - 同じラベルのインシデントが OPEN の間は、一致するログが来ても **新しいインシデントにならず、通知も出ない**
  - そのたびに自動クローズまでのタイマーが延びる（最後に一致したログから `auto_close` の時間が経つまでクローズされない。実測で、最後の一致から約 30〜35 分後にクローズ）
  - ラベル抽出がないポリシー（今回の A2）は、全事象が 1 つのインシデントにまとめられる。あとから起きた別の 5xx 事象（アプリ停止）は通知されなかった
  - → 事象ごとに通知したい場合は、**`label_extractors` で識別子（IG 名、ジョブ ID、インスタンス名など）を抽出する**。また、`auto_close` を短くしすぎると通知が増えすぎる点とのバランスを考える
- `label_extractors` で抽出した値は、インシデントのラベルとして見える（Monitoring API v3 `projects/<P>/alerts` の `log.extractedLabels`）

### 5.3 インシデントの確認方法（API）

```bash
TOKEN=$(gcloud auth print-access-token)
curl -s -G -H "Authorization: Bearer $TOKEN" \
  "https://monitoring.googleapis.com/v3/projects/<P>/alerts" \
  --data-urlencode "pageSize=50" --data-urlencode "orderBy=open_time desc"
# openTime / closeTime / state / policy.displayName / log.extractedLabels / metric.labels / resource.labels
```

- インシデントの発報やクローズは、監視対象リソースのログとして `monitoring.googleapis.com%2FViolationOpenEventv1` などにも記録される

---

## 6. プライベート Uptime Check（内部 IP の外形監視）

- 構成: Service Directory の namespace → service → endpoint（VIP:80 と `network=projects/<NUMBER>/locations/global/networks/<VPC>`）。Uptime Check は `checker_type = "VPC_CHECKERS"`、`monitored_resource.type = "servicedirectory_service"`
- 必要な IAM: Monitoring サービスエージェント `service-<NUMBER>@gcp-sa-monitoring-notification.iam.gserviceaccount.com` に、`roles/servicedirectory.viewer` と `roles/servicedirectory.pscAuthorizedService`
  - このエージェントがまだない場合は、`gcloud beta services identity create --service=monitoring.googleapis.com` で作る
- チェッカーは 6 拠点（usa-virginia / usa-oregon / usa-iowa / eur-belgium / apac-singapore / sa-brazil-sao_paulo）から実行される。**内部 ALB では `allow_global_access=true` が必須**
- アラート: `check_passed` を ALIGN_NEXT_OLDER と REDUCE_COUNT_FALSE で集計し、> 1 が 60 秒続いたら発報。全台停止（最初の 503）から約 2 分 10 秒で発報し、回復も約 2 分で検知した

---

## 7. 検知方式の選び方（結論）

| 検知したいこと | 推奨 | 理由 |
|---|---|---|
| VM 停止を速く（計画停止も含めてよい） | A7 監査ログ（stop 完了） | 約 1 分。誰が止めたかも分かる |
| 意図しない VM 停止（ALB の観点） | A6 バックエンド別リクエスト数の途絶 | VM 停止とアプリ停止の両方に反応する。常時トラフィックが前提で、遅延は約 6〜7 分 |
| アプリだけが止まったとき（VM は動いている） | A1 ヘルスチェックログ（`previousHealthState="HEALTHY"` 付き） | 約 23 秒と最も速い。ただし VM 停止は検知できない |
| サービス全体の停止 | A4 プライベート Uptime Check（＋ A2 の 5xx ログ） | クライアントから見た可用性を直接見られる |
| Scheduler の起動・停止の失敗 | S1（ログ）＋ S3（監査ログ）。集計やダッシュボードが要るなら S2 | S1 と S3 は 1 分以内に検知できる |
| 起動・停止が受け付けられたのに VM の状態が変わらない | S3（再現はできていない）。または A5 / A7 で実際の状態を突き合わせる | Scheduler から見ると成功扱いになるため |

**計画停止によるノイズ対策**: 毎日 19 時の Scheduler 停止で、A5 / A6 / A7 は必ず発報する。運用するなら、次のいずれかが必要。
- 停止時間帯のスヌーズ（Cloud Monitoring の Snooze）、または Datadog の Downtime
- A7 を `principalEmail` で分け、Scheduler の SA による停止は通知しない
- A5 / A6 を営業時間帯だけ有効にする

---

## 8. Terraform と運用の注意点

| 事象 | 対処 |
|---|---|
| ADC（`application-default login`）が失効している | `export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)` で google provider を動かせる（有効期限は約 1 時間なので、コマンドのたびに取り直す） |
| Compute API がまだ有効でないプロジェクト | `google_project_service` で有効化し、各リソースに `depends_on` を付ける。今回は一度で通った。**カスタムロールにも `depends_on` を付けておく**（IAM API） |
| 指標条件の resource.type が抜けている、または間違っている | Apply 時に 400 エラーになる（5.1 参照）。plan では検出できない |
| `allow_global_access` の変更 | 転送ルールの作り直しになり、VIP が停止する |
| `desired_status` を指定しない | Scheduler が VM を止めても、Terraform は差分として扱わない（plan に差分なし）。予定どおりの挙動 |
| Scheduler ジョブ作成直後の 1 回目の plan | 5 件すべてに in-place の差分が出た。2 回目以降は出ない（推測: 作成後にサーバー側で値が補完されたため） |
| IAP SSH で鍵にパスフレーズがある | 非対話環境では使えない。`--ssh-key-file=<パスフレーズなしの使い捨て鍵> --ssh-key-expire-after=2h` で回避する。または、試験クライアントの起動スクリプトでトラフィックを自動生成し、結果は LB のログで見る（今回はこの方式） |
| OS Login に登録した鍵 | `--ssh-key-expire-after` を付ければ期限切れで消える。手動で消すなら `gcloud compute os-login ssh-keys remove --key-file=<pub>` |
| カスタムロールの削除 | 削除後 7 日間は同じ ID で作り直せない。すぐ作り直すなら `name_prefix` を変える |
