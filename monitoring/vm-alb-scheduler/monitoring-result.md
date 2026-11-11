# 監視設計（Datadog 前提）

検証（[RESULTS.md](RESULTS.md) / [test-history.md](test-history.md)）の結果をもとに、実装する監視を以下の 4 つに決めた。このドキュメントは、それを Datadog で実装するための設計情報をまとめたもの。

| ID | 監視 | 検知したい事象 | Datadog のモニター種別 | 検証時の GCP 側の相当 |
|---|---|---|---|---|
| M1 | ALB のリクエストログ 5xx 系 | VM の停止・アプリの停止でユーザーにエラーが返った（全台停止を含む） | Log Monitor | A2 |
| M2 | Compute Engine の Uptime | VM の停止（ALB の状態に依らない） | Metric Monitor | A5 |
| M3 | Cloud Scheduler のジョブの実行ログ | Scheduler の起動・停止の失敗（権限不足、API の受付拒否など） | Log Monitor | S1 |
| M4 | Compute Engine の監査ログ | 起動・停止の API 呼び出しの失敗、および受付後の処理の失敗 | Log Monitor | S3 |

- M3 と M4 は必ずセットで使う。Scheduler の実行ログに残るのは Compute API の受付結果（HTTP 応答）だけ。受付後に起動・停止の処理が失敗しても（例: `ZONE_RESOURCE_POOL_EXHAUSTED`）、Scheduler 上は 200 の成功として記録される。この失敗は M4 でしか拾えない
- ヘルスチェックログは監視に使わない。VM の停止（TERMINATED）では 1 台でも 2 台でもログが出ないことを検証で確認した（[test-history.md](test-history.md)）

---

## 1. 前提

| 項目 | 値 |
|---|---|
| プロジェクト ID | `miumosh-sb-test01`（検証環境。本番では置き換える） |
| リージョン | `asia-northeast1` |
| 内部 ALB の転送ルール | `vas-fr-http`（VIP `10.10.0.10`）／バックエンドサービス `vas-bes` |
| VM | `vas-web-1`（asia-northeast1-a）、`vas-web-2`（asia-northeast1-b） |
| Scheduler ジョブ | `vas-web-1-start`、`vas-web-1-stop`、`vas-web-2-start`、`vas-web-2-stop`（ロケーション `asia-northeast1`） |
| Scheduler の実行 SA | `vas-scheduler@miumosh-sb-test01.iam.gserviceaccount.com` |
| Datadog への取り込み | 指標: Datadog GCP インテグレーション（STS）／ログ: Log Router シンク → Pub/Sub → Dataflow（`Cloud_PubSub_to_Datadog`）→ Datadog Logs（[datadog/log_forwarding.tf](datadog/log_forwarding.tf)） |
| Datadog のログ属性 | 既存の Workflows の監視と同じ書き方（ログレベルは `status:(error OR ...)`、GCP の項目は `@protoPayload...` など）にそろえる。詳細は [monitor-result-datadog.md](monitor-result-datadog.md) |

---

## 2. 監視するメトリクスの詳細

指標（メトリクス）で監視するのは M2 だけ。M1・M3・M4 はログ監視なので「3. ログ収集・ログ監視」に記載する。

| ID | 監視名 | 監視対象メトリクス | 評価期間 | アラート判定条件 | 閾値（危険） | 閾値（警告） |
|---|---|---|---|---|---|---|
| M2 | VM 停止（Uptime 途絶） | `gcp.gce.instance.uptime`（GCP: `compute.googleapis.com/instance/uptime`）<br>1 分ごとの「その 1 分間に VM が動いていた秒数」。動いていれば約 60、停止すると値が届かなくなる<br>対象: `project_id:miumosh-sb-test01`、`instance_name:vas-web-*`、VM 別に評価<br>値が届かない時間を 0 として扱う（`default_zero()`） | 直近 10 分の平均（`avg(last_10m)`）<br>evaluation_delay 300 秒（GCP 指標の取り込み遅延を吸収） | 閾値以下になったら（メトリクス <= 閾値） | **0**（直近 10 分間ずっと停止していた） | **30**（直近 10 分のうち約半分以上停止していた） |

- 閾値の考え方: 動いている VM は平均約 60。停止した時間を 0 として平均を取るので、10 分のうち停止していた割合に比例して値が下がる（半分停止で 30、全部停止で 0）。警告は停止から約 5 分、危険は約 10 分で到達する（それぞれ evaluation_delay と取り込み遅延が加わる）
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

- 60 は「1 分間ずっと動いていたときの値（60 秒）」、0 は「止まっていて値が届かない 1 分を `default_zero()` で 0 にしたもの」
- 警告の閾値 30 ＝ 60 ×（10 分のうち動いていた割合 5/10）。「5 分以上止まったら警告」にしたいので 30 にしている
- 一般式: 警告の閾値 ＝ 60 ×（10 − 警告にしたい停止分数）÷ 10。例: 3 分以上で警告にしたいなら 60 × 7 ÷ 10 ＝ 42

- 「閾値以下」を使う理由: VM が停止すると値が 0 になるのではなく、値そのものが届かなくなる。そのままでは比較できないので、`default_zero()` で届かない時間を 0 として扱い、「平均が閾値以下」で判定する
- 平均を使う理由: 取り込みの揺らぎで 1 点欠けても、平均は約 54 に下がるだけで警告（30）に届かない。最小値（min）で判定すると 1 点の欠けで誤検知する
- 未検証: Datadog 上で正常時の値が約 60 になっているかを導入時に確認する。取り込み間隔の関係で値の大きさが違う場合（例: 5 分まとめて約 300）は、警告を正常値の半分、危険を 0 にする
- 遅延: GCP 側（A5、途絶 180 秒）の実測は停止から約 8.7 分。Datadog では上記のとおり、警告まで約 5 分＋遅延、危険まで約 10 分＋遅延（未検証）
- 計画停止（月次メンテナンス）の間は Downtime で抑止する。VM を削除した場合も発報する
- その他の設定: `require_full_window = false`、`renotify_interval = 60`（分）

---

## 3. ログ収集・ログ監視

- エラー判定文字列・除外文字列は、GCP 側のログの条件として Cloud Logging の検索クエリの構文で書いている（`=~` は正規表現、`.*` はワイルドカード）。Datadog の検索クエリに書き直したものは [monitor-result-datadog.md](monitor-result-datadog.md)
- 除外文字列は、エラー判定文字列に `NOT` 付きで追加する条件。1 つのエラー判定文字列に複数ある場合は、改行して並べている（すべて AND で連結する）
- `logName` を必ず条件に入れている。理由: Cloud Monitoring のアラートのイベントログ（`monitoring.googleapis.com%2FViolationOpenEventv1` など）が、監視対象と同じ `resource.type`（`internal_http_lb_rule`、`cloud_scheduler_job`）で記録されることを検証で確認したため。`resource.type` だけで絞ると、これらを誤って拾う

| ID | 目的 | マネージドサービスの種類 | リソース名 | プロジェクトID | ログの種類 | 保存先ログスコープ名 | エラー判定文字列 | 除外文字列 |
|---|---|---|---|---|---|---|---|---|
| L1（M1） | 内部 ALB がクライアントに 5xx を返したことを検知する（VM・アプリの停止、全台停止） | Cloud Load Balancing（リージョン内部 Application Load Balancer） | 転送ルール `vas-fr-http`<br>（バックエンドサービス `vas-bes`、URL マップ `vas-urlmap`） | `miumosh-sb-test01` | ALB のリクエストログ<br>logName: `projects/miumosh-sb-test01/logs/loadbalancing.googleapis.com%2Frequests`<br>resource.type: `internal_http_lb_rule`<br>（バックエンドサービスの `log_config` でサンプリング率 1.0 を設定していることが前提） | GCP: `_Default` ログバケット（`projects/miumosh-sb-test01/locations/global/buckets/_Default`、保持 30 日）<br>Datadog: ログインデックス `main` | `logName="projects/miumosh-sb-test01/logs/loadbalancing.googleapis.com%2Frequests" resource.type="internal_http_lb_rule" resource.labels.forwarding_rule_name="vas-fr-http" httpRequest.status>=500 httpRequest.status<600` | `NOT httpRequest.userAgent=~"^GoogleStackdriverMonitoring-UptimeChecks"`（Uptime Check を併用する場合。全台停止時に重複して数えるため）<br>`NOT httpRequest.requestUrl=~"/healthz"`（アプリ独自の死活確認パスがあり、その 5xx を別監視する場合。パスは環境に合わせる） |
| L2（M3） | Cloud Scheduler による VM の起動・停止ジョブの実行失敗を検知する（権限不足、API の受付拒否、Scheduler からの到達失敗） | Cloud Scheduler | ジョブ `vas-web-1-start`<br>`vas-web-1-stop`<br>`vas-web-2-start`<br>`vas-web-2-stop`<br>（ロケーション `asia-northeast1`） | `miumosh-sb-test01` | Cloud Scheduler の実行ログ<br>logName: `projects/miumosh-sb-test01/logs/cloudscheduler.googleapis.com%2Fexecutions`<br>resource.type: `cloud_scheduler_job`<br>`@type`: `type.googleapis.com/google.cloud.scheduler.logging.AttemptFinished` | GCP: `_Default` ログバケット（`projects/miumosh-sb-test01/locations/global/buckets/_Default`、保持 30 日）<br>Datadog: ログインデックス `main` | `logName="projects/miumosh-sb-test01/logs/cloudscheduler.googleapis.com%2Fexecutions" resource.type="cloud_scheduler_job" resource.labels.job_id=~"^vas-web-.*-(start\|stop)$" jsonPayload."@type"="type.googleapis.com/google.cloud.scheduler.logging.AttemptFinished" severity>=ERROR` | `NOT resource.labels.job_id="vas-failure-test"`（検証用に意図的に失敗させるジョブ。`job_id` の正規表現で既に対象外だが、命名を変えたときの保険。本番では作らない） |
| L3（M4） | Compute Engine の起動・停止の失敗を検知する（API 呼び出しの拒否と、受付後の処理の失敗の両方。L2 では受付後の失敗が「成功」に見えるため、その補完） | Compute Engine | インスタンス `vas-web-1`（asia-northeast1-a）<br>`vas-web-2`（asia-northeast1-b） | `miumosh-sb-test01` | 監査ログ（管理アクティビティ）<br>logName: `projects/miumosh-sb-test01/logs/cloudaudit.googleapis.com%2Factivity`<br>resource.type: `gce_instance`<br>methodName: `v1.compute.instances.start`／`v1.compute.instances.stop` | GCP: `_Required` ログバケット（`projects/miumosh-sb-test01/locations/global/buckets/_Required`、保持 400 日、変更不可）<br>Datadog: ログインデックス `main` | `logName="projects/miumosh-sb-test01/logs/cloudaudit.googleapis.com%2Factivity" resource.type="gce_instance" protoPayload.serviceName="compute.googleapis.com" protoPayload.methodName=~"compute\.instances\.(start\|stop)$" protoPayload.resourceName=~"/instances/vas-web-[0-9]+$" severity>=ERROR` | `NOT protoPayload.authenticationInfo.principalEmail="<運用者・CI のアカウント>"`（Scheduler 以外の手動操作の失敗を通知対象から外す場合。手動操作の失敗も拾いたいなら設定しない） |

### 3.1 判定条件を細かくしている理由

| ID | 条件 | 理由 |
|---|---|---|
| L1 | `httpRequest.status:[500 TO 599]` で判定し、`severity` は使わない | 内部 ALB のリクエストログは、5xx でも `severity` が `WARNING` になる（検証時の 5xx 174 件はすべて WARNING）。`ERROR` で絞ると何も拾えない |
| L1 | `jsonPayload.proxyStatus` は条件に入れない | 5xx 174 件のうち、`proxyStatus` が付いていたのは 27 件だけ（`failed_to_pick_backend` 22 件、`failed_to_connect_to_backend` 5 件）。全台停止中の 5xx の大半は `proxyStatus` が無かった。原因の切り分けには使えるが、判定には使えない |
| L1 | `forwarding_rule_name` で絞る（`backend_service_name` は使わない） | 内部 ALB のリクエストログには `backend_service_name` ラベルが無い。バックエンドサービス名は `backend_target_name` に入る。全台停止時は `backend_name` が空になる |
| L2 | `AttemptFinished` かつ `severity:ERROR` | 実行ごとに `AttemptStarted`（INFO）と `AttemptFinished` が出る。失敗時は `AttemptFinished` が ERROR になり、`jsonPayload.status`（例: `PERMISSION_DENIED`）と `httpRequest.status`（例: 403）が付く。成功時は INFO・200 で、`status` は付かない |
| L2 | `job_id:vas-web-*` で絞る | 同じプロジェクトにある他の Scheduler ジョブの失敗を拾わないため |
| L3 | `methodName` を `*compute.instances.start`／`*compute.instances.stop` の後方一致にする | API のバージョンで接頭辞が変わる（`v1.`、`beta.`）。後方一致にすると `instances.startWithEncryptionKey` などの別メソッドは拾わない |
| L3 | `severity:ERROR` | 正常な起動・停止は、処理開始（`operation.first=true`）と完了（`operation.last=true`）の 2 件が NOTICE で出る。403 で拒否されると ERROR が 1 件出て、`protoPayload.status.code=7` が付く（検証で確認）。受付後の処理の失敗は、完了ログが ERROR になる想定（未再現） |

### 3.2 ログ監視の通知条件（Datadog Log Monitor）

上の表のエラー判定文字列（除外文字列を適用した後）に一致したログの件数で発報する。Datadog のモニター設定（クエリ・通知メッセージ・Terraform）は [monitor-result-datadog.md](monitor-result-datadog.md)。

| ID | 集計 | グループ化 | 閾値（危険） | 閾値（警告） | 補足 |
|---|---|---|---|---|---|
| L1（M1） | 直近 5 分の件数（`rollup("count").last("5m")`） | なし（全台停止では `backend_name` が空になるため） | ≧ 20 件／5 分（全台停止など、5xx が継続する状態） | ≧ 1 件／5 分（1 台停止の瞬間やアプリ停止の切り替わり） | 検証時の実測（2 秒ごとのリクエスト）: 全台停止は約 30 件／分、アプリ停止は 4 件、VM 1 台の停止は 1 件。危険の閾値は本番のリクエスト量で見直す。`renotify_interval = 60` |
| L2（M3） | 直近 5 分の件数 | `job_id` 別 | ≧ 1 件 | 設定しない（1 件の失敗がそのまま起動・停止の失敗を意味する） | `retry_count = 0` なので 1 回の失敗で確定。GCP 側（S1）の実測は失敗から約 35〜49 秒 |
| L3（M4） | 直近 5 分の件数 | VM（`protoPayload.resourceName`）別 | ≧ 1 件 | 設定しない（同上） | GCP 側（S3）の実測は失敗から約 20〜49 秒（403 で確認） |

共通: `enable_logs_sample = true`（通知に該当ログを添付）、`notify_no_data = false`。月次メンテナンス中の扱いは 5 章。

### 3.3 GCP 側のログ転送（Log Router シンク）

Datadog に送るログは、シンクのフィルタで 3 種類に絞る（Dataflow の処理量と Datadog の取り込み量を抑えるため）。[datadog/log_forwarding.tf](datadog/log_forwarding.tf) の `forward_filter` に相当する。

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
```

- L1 は 5xx だけを送る。全リクエストを送ると、2 秒ごとのリクエストだけで約 1,300 件／時になる（検証時は 85 分で 2,580 件）
- L2 は成功ログ（INFO）も送る。成功・失敗の履歴を Datadog 上で追えるようにするため（件数は 1 ジョブ 1 回あたり 2 件）
- L3 も成功ログ（NOTICE）を送る。「誰が・いつ起動・停止したか」を Datadog 上で確認できるようにするため
- `_Required` バケットの監査ログもシンクで転送できる（シンクはバケットとは別に、ルーティング時点のログを対象にする）

---

## 4. この 4 つの監視で検知できること・できないこと

| 事象 | M1 5xx | M2 Uptime | M3 Scheduler | M4 監査 | 備考 |
|---|---|---|---|---|---|
| VM 1 台が停止（Scheduler による計画停止） | △ 警告（1 件程度） | ◯ | – | – | 計画停止なので Downtime で抑止 |
| VM 1 台が予期せず停止（手動操作・障害） | △ 警告（1 件程度） | ◯ | – | – | ゲスト OS 内からの shutdown・ホストの障害は監査ログ（activity）に出ない。M2 で拾う |
| VM 2 台とも停止 | ◯ 危険 | ◯ | – | – | 5xx が継続して出る |
| VM は動いているがアプリが停止 | △ 警告（数件） | × | – | – | 1 台なら ALB が切り離すので 5xx は数件だけ。アプリの死活監視が必要なら別途検討（ヘルスチェックログ、Datadog Agent など） |
| Scheduler の権限不足（403） | – | – | ◯ | ◯ | 検証で確認（T4、T5） |
| API が受付時点で拒否（4xx） | – | – | ◯ | ◯ | 403 と同じ仕組み。未検証 |
| 受付後に起動・停止の処理が失敗（リソース不足など） | – | 起動失敗なら × のまま（もともと停止中） | **×（200 の成功に見える）** | ◯（想定） | 未再現。保険としてメンテナンス後の確認手順で VM の状態を確認する |
| Scheduler が Compute API に到達できない・タイムアウト | – | – | ◯ | × | 未検証 |
| ジョブが実行されない（一時停止、削除、スケジュールの設定ミス） | – | – | × | × | ログ自体が出ない。メンテナンス当日に実行履歴を確認する |

---

## 5. 月次メンテナンス時の扱い

詳細は [monitoring-and-maintenance.md](monitoring-and-maintenance.md) の 2 章。この 4 つの監視に当てはめると次のとおり。

| ID | メンテナンス中 | 理由 |
|---|---|---|
| M1 | 2 台同時停止なら Downtime。ローリング（1 台ずつ）なら抑止しない | ローリングなら 5xx は 1 件程度で警告止まり。危険が出たら、ローリングが崩れている（2 台目を止める前に 1 台目が戻っていない） |
| M2 | Downtime（対象: `instance_name:vas-web-*`、停止ジョブの時刻から起動ジョブの時刻＋20 分まで） | 計画停止そのものを検知してしまう。Downtime の終了後も No Data が続けば、起動の失敗に気づける |
| M3 | 抑止しない | メンテナンスで一番検知したい事象（起動・停止の失敗） |
| M4 | 抑止しない | 同上。M3 では見えない受付後の失敗を拾う |

---

## 6. 未検証の事項と、本番導入前に確認すること

| 項目 | 内容 |
|---|---|
| Datadog 側の実装 | 今回の検証では Datadog への取り込み・モニターは動かしていない。属性名の書き方、取り込み遅延を導入時に確認する（[monitor-result-datadog.md](monitor-result-datadog.md) の 5 章） |
| M2 の遅延 | GCP 側（A5）の実測は約 8.7 分。Datadog の GCP 指標の取り込み遅延と evaluation_delay の分だけ、さらに遅くなる |
| M1 の危険の閾値 | 検証の 2 秒ごとのリクエストを前提にした値。本番のリクエスト量で見直す |
| M4 の受付後の失敗 | `ZONE_RESOURCE_POOL_EXHAUSTED` などの非同期の失敗は再現できていない。完了ログ（`operation.last=true`）が ERROR になる想定 |
| 既存サンプルとの差分 | [datadog/monitors.tf](datadog/monitors.tf) の DD-S1 は `resource.type` と `severity` だけで判定しており、このドキュメントの L2 より条件が粗い。このドキュメントに合わせて更新する場合は別途対応する |
