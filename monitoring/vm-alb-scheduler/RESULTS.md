# 検証結果（vm-alb-scheduler）

- 実施日: 2026-11-10（UTC。日本時間では 11-11 の 02:13〜03:30 ごろ）
- プロジェクト: `miumosh-sb-test01` / リージョン: `asia-northeast1`
- Terraform 1.15.5、google provider 7.46.2
- 監視の実装: Cloud Monitoring（本体ディレクトリ）。Datadog は今回実装しておらず、知見だけを `datadog/` に反映した
- 時刻はすべて **UTC**。検知遅延は「操作した時刻、または事象が起きた時刻 → インシデントの openTime」で測った

---

## 1. 結論

### 1.1 内部 ALB 配下の VM 停止を検知できるか

| 停止の種類 | 検知できた方式 | 検知できなかった方式 |
|---|---|---|
| **VM 停止**（Scheduler による stop、1 台） | **A7** 監査ログ（約 1 分 16 秒）、**A6** バックエンド別リクエスト数の途絶（約 7 分）、**A5** VM の uptime 途絶（約 8.7 分） | **A1 / A3（ヘルスチェックログ）は検知できない**。停止した VM はヘルスチェックの対象から外れ、UNHEALTHY 遷移のログが出ないため。A2 / A4 は 1 台停止では反応しない |
| **アプリ停止**（VM は動いたまま、1 台） | **A1** ヘルスチェックログ（約 23 秒）、**A3** ログベース指標（約 3.4 分）、**A6**（約 5.9 分）、**A2** 停止直後に数秒だけ 503 が出る | A5（VM 自体は動いている）、A4（もう 1 台が応答する） |
| **全台停止**（2 台とも） | **A4** プライベート Uptime Check（最初の 503 から約 2 分 10 秒）、**A2** 5xx のリクエストログ、A5 / A6 / A7 | – |

- **「ALB がログから VM 停止を検知する」という当初の想定（ヘルスチェックログ）は、VM 停止には使えない。** ヘルスチェックログで検知できるのは「VM は動いているが応答しない」場合（アプリ停止やハングなど）に限られる
- VM 停止をログで最も速く検知できるのは、**監査ログでの `compute.instances.stop` 完了（A7）**。ただし計画停止や、すでに止まっている VM への stop（no-op）でも発報する
- ALB の観点で VM 停止とアプリ停止の **両方** を 1 つの方式で拾えるのは、**A6（`backend_request_count` がバックエンドごとに途絶えたら発報）**。ただし常にトラフィックがあることが前提で、遅延は約 6〜7 分

### 1.2 Cloud Scheduler の起動・停止の失敗を検知できるか

| 方式 | 結果 | 遅延（403 失敗の場合） |
|---|---|---|
| **S1** ログ（`AttemptFinished` かつ `severity>=ERROR`） | ◯ | 約 35〜49 秒 |
| **S2** ログベース指標（`job_id` ごと） | ◯ | 約 3.4〜4 分 |
| **S3** 監査ログ（`compute.instances.start/stop` かつ `severity>=ERROR`） | ◯（**API が 403 を返した段階でも発報する**） | 約 20〜49 秒 |
| S4 Cloud Scheduler の組み込み指標 | ×（**`cloudscheduler.googleapis.com/*` の指標は存在しない**） | – |

→ **ログ（S1）と指標（S2）の両方で検知できる**。ただし指標の元は「ログベース指標」で、Scheduler の組み込み指標ではない。

---

## 2. 事前に置いた想定と実際の違い（要確認事項 R1〜R9 の答え合わせ）

| # | 想定 | 実際 | 対応 |
|---|---|---|---|
| R1 | VM 停止時、ヘルスチェックログに UNHEALTHY 遷移が出る | **出ない**。停止から 6 分以上たってもログは 0 件。停止した VM は `get-health` の結果からも消える | VM 停止の検知に A5 / A6 / A7 を追加した |
| R2 | ヘルスチェックログのフィールド名 | `jsonPayload.healthCheckProbeResult.{healthState, previousHealthState, detailedHealthState, ipAddress, …}` で合っていた。`resource.type` は **`gce_instance_group`** | フィルタに `resource.type` を追加した |
| – | （想定外）起動直後の誤検知 | 起動時に `UNHEALTHY(UNKNOWN) → UNHEALTHY(TIMEOUT)` のように、**詳細状態だけが変わってもログが出る**。A1 が起動時に発報した | `previousHealthState="HEALTHY"` の条件を追加し、HEALTHY から UNHEALTHY への遷移だけを拾うようにした。以降、起動時の誤検知はない |
| – | （想定外）ログベース指標のリソースタイプ | `gce_instance_group` は Monitoring のリソースタイプとして **存在しない** ため、ヘルスチェックログから作ったログベース指標は **`resource.type="global"`** になる | A3 のフィルタを `resource.type="global"` にした |
| R3 | 内部 ALB のログに `backend_service_name` があり、全台停止時は `statusDetails="failed_to_pick_backend"` になる | **どちらも違った**。ラベルは `backend_target_name` / `forwarding_rule_name` / `backend_name` など。`statusDetails` フィールドは存在せず、`jsonPayload.proxyStatus` に入るが **毎回は出ない**（後述） | A2 の条件を `forwarding_rule_name` と `httpRequest.status>=500` に変更した |
| R4 | Cloud Scheduler の組み込み指標 | 存在しない | S2（ログベース指標）で代替する |
| R5 | ログベース指標を作った直後にアラートを作るとエラーになる | 発生した（`The resource name does not represent a known descriptor`）。ただし本当の原因は、指定した resource.type が間違っていたこと | resource.type を直したら解消した |
| – | （想定外）指標条件に resource.type が必須 | `condition_threshold.filter` で `resource.type` を指定しないと **400 エラー**（`must specify a restriction on "resource.type"`） | すべての指標条件に resource.type を指定した |
| R7 | Monitoring サービスエージェントがなく、IAM 付与に失敗する | Apply 前に `gcloud beta services identity create --service=monitoring.googleapis.com` で作成したため、問題は起きなかった | 手順に含めた |
| R8 | プライベート Uptime Check が内部 ALB の VIP に届くか | **最初は 6 拠点すべてで失敗した**。転送ルールで `allow_global_access=true` にしたら成功した | `lb.tf` に反映した（転送ルールは作り直しになる） |
| R9 | ADC が失効している | `application-default login` をしなくても、`GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)` で Terraform を実行できた | 手順に記載した |
| T4 | 存在しない VM への start は 404 になる | **403 PERMISSION_DENIED** になった。Scheduler の SA には VM 単位の権限しかなく、存在確認の前に権限チェックで拒否されるため | 404 を再現するには、プロジェクト単位の権限が必要 |

---

## 3. シナリオ別の結果（時系列）

### 3.0 構築と T0（Apply 直後）

| 時刻 | 事象 |
|---|---|
| 17:13 頃 | Apply（53 リソース）。A3 と A4 だけ resource.type が足りずに失敗 → 修正して再度 Apply |
| 17:15:50〜17:16:02 | 起動時のヘルスチェックログ: web-1 が `UNHEALTHY(UNKNOWN)→UNHEALTHY(TIMEOUT)`、その後 `→HEALTHY`。web-2 は `→HEALTHY` |
| 17:17:49 | **A1 が発報**（修正前のフィルタ。起動時の TIMEOUT に反応した。想定 T0 の「誤検知」が実際に起きた）→ フィルタを修正した |
| 17:20〜 | Uptime Check が 6 拠点すべてで False（グローバルアクセスがないため）。17:22:28 に A4 が発報 |
| 17:22:23 | 転送ルールを `allow_global_access=true` で作り直し（短時間、VIP が停止する） |
| 17:23:13 | Uptime Check が成功し始める。17:24:24 に A4 が回復 |

### 3.1 T4: 失敗再現ジョブ（存在しない VM への start）

| 時刻 | 事象 | 実行からの経過 |
|---|---|---|
| 17:22:47 | `gcloud scheduler jobs run vas-failure-test` | 0 |
| 17:22:55 | `AttemptFinished` severity=ERROR、`status=PERMISSION_DENIED`、HTTP 403 | +8 秒 |
| 17:23:07 | **S3** 発報（監査ログ。403 で拒否された呼び出しも ERROR として記録される） | +20 秒 |
| 17:23:22 | **S1** 発報（ラベル `job_id=vas-failure-test`、`status=PERMISSION_DENIED`） | +35 秒 |
| 17:26:13 | **S2** 発報（ラベル `job_id=vas-failure-test`） | +3 分 26 秒 |
| 17:27:26 | S2 が自動で回復（値が 0 に戻ったため） | |
| 17:58:34 | S1 と S3 が自動でクローズ（最後の一致から約 30 分。`auto_close=1800s`） | |

### 3.2 T1（1 回目）: Scheduler で web-1 を停止（A5〜A7 を追加する前）

| 時刻 | 事象 |
|---|---|
| 17:26:27 | `vas-web-1-stop` を実行 |
| 17:26:31 | `AttemptFinished` INFO、HTTP 200（Scheduler としては成功） |
| 17:26:30 / 17:27:17 | 監査ログ `v1.compute.instances.stop`: `operation.first` → `operation.last`（停止の所要時間は約 47 秒） |
| 17:27:05 / 17:27:10 | 内部 ALB のログに 2 件: `status` なし、`proxyStatus: error="connection_terminated"; details="client_disconnected_before_any_response"`（シャットダウン中の web-1 に送られ、curl が 3 秒でタイムアウト） |
| 17:27:25 | VM が TERMINATED になる。`get-health` から web-1 が **消える** |
| 〜17:33 | **ヘルスチェックログは 0 件**。A1 / A3 は発報しない。トラフィックは web-2 が 200 で処理し続けた |

### 3.3 T2: 続けて web-2 も停止（2 台とも停止）

| 時刻 | 事象 | 実行からの経過 |
|---|---|---|
| 17:34:14 | `vas-web-2-stop` を実行 | 0 |
| 17:35:08 | 最初の 503（`backend_name=""`、`backend_type=UNKNOWN`） | +54 秒 |
| 17:36:28 | A2 のフィルタを修正し、A5 / A6 / A7 を追加（Apply） | |
| 17:37:18 | **A4** 発報（プライベート Uptime Check） | 最初の 503 から +2 分 10 秒 |
| 17:38:34 | **A2** 発報（ポリシー更新の直後なので、遅延の参考にはならない） | |
| 17:40:05〜17:42:07 | A5 / A6 が web-1 と web-2 の分を発報（ポリシーを作った時点ですでにデータが途絶えていたため、遅れて発報） | |

- 503 の `proxyStatus` は、**17:39:04 までは空** で、**17:39:06 以降は `error="destination_unavailable"; details="failed_to_pick_backend"`** になった。同じ状況でも出たり出なかったりするので、`proxyStatus` に頼るフィルタは避ける

### 3.4 T3: 2 台とも起動

| 時刻 | 事象 |
|---|---|
| 17:38:56 | `vas-web-1-start` と `vas-web-2-start` を実行 → 17:39:01 と 17:39:05 に HTTP 200 |
| 17:39:10 / 17:39:13 | ヘルスチェックログ `UNHEALTHY(UNKNOWN)→UNHEALTHY(TIMEOUT)`（新しいフィルタには該当しない） |
| 17:39:41 | web-1 `UNHEALTHY→HEALTHY`。17:39:46 には 2 台とも HEALTHY（**起動指示から約 50 秒**） |
| 17:39:42 | 最後の 503 |
| 17:41:53 | A4 が回復 |

### 3.5 T1b: web-1 のアプリだけを停止（VM は動いたまま）

| 時刻 | 事象 | 停止からの経過 |
|---|---|---|
| 17:40:05 | `systemctl stop simple-web`（IAP SSH） | 0 |
| 17:40:16 | ヘルスチェックログ `HEALTHY→UNHEALTHY(TIMEOUT)` | +11 秒 |
| – | **A1 は新しいインシデントを作らなかった**。17:17 の誤検知でできた A1 インシデント（ラベル `ip=10.10.1.3, TIMEOUT`）がまだ開いていて、同じラベルとしてまとめられた | |
| 17:43:45 | **A3** 発報 → 17:44:59 に回復 | +3 分 40 秒 |
| 17:46:55 | アプリを再開 | |
| 18:15:42 | 17:17 の A1 インシデントがクローズ（**最後に一致したログ（17:40:16）から約 35 分**。同じラベルのログが来ると、自動クローズまでの時間がリセットされる） | |

### 3.6 T1b': web-2 のアプリだけを停止（A1 の単体確認）

| 時刻 | 事象 | 停止からの経過 |
|---|---|---|
| 17:57:27 | `systemctl stop simple-web`（web-2） | 0 |
| 17:57:31〜17:57:39 | 内部 ALB のログに 503 が 4 件: `proxyStatus: error="connection_refused"; details="failed_to_connect_to_backend"`、`backend_name=vas-ig-web-2` | +4〜12 秒 |
| 17:57:37 | ヘルスチェックログ `HEALTHY→UNHEALTHY(TIMEOUT)`（ip 10.10.1.2） | +10 秒 |
| 17:57:50 | **A1** 発報（ラベル `ip_address=10.10.1.2, detailed_state=TIMEOUT`） | **+23 秒** |
| 18:00:48 | **A3** 発報 → 18:01:49 に回復 | +3 分 21 秒 |
| 18:03:18 | **A6** 発報（`backend_name=vas-ig-web-2`） | +5 分 51 秒 |
| 18:03:40 頃 | アプリを再開 → 18:03:46 に HEALTHY | |
| 18:06:43 | A6 が回復 | |

- A2 は 17:38 から開いたままのインシデントに上の 503 がまとめられ、新しい通知は出なかった（A2 にはラベル抽出がないため、すべて 1 つのインシデントになる）

### 3.7 T1（2 回目）: Scheduler で web-1 を停止（A5〜A7 を検証）

| 時刻 | 事象 | 実行からの経過 |
|---|---|---|
| 18:07:21 | `vas-web-1-stop` を実行 | 0 |
| 18:07:23 | 監査ログ stop `operation.first=true` | +2 秒 |
| 18:08:11 | 監査ログ stop `operation.last=true`（停止完了） | +50 秒 |
| 18:08:37 | **A7** 発報（`principal=vas-scheduler@…`） | **+1 分 16 秒** |
| 18:14:16 | **A6** 発報（`backend_name=vas-ig-web-1`） | **+6 分 55 秒** |
| 18:16:03 | **A5** 発報（`instance_name=vas-web-1`） | **+8 分 42 秒** |
| – | A1 / A3 / A2 / A4 は発報しない（想定どおり） | |
| 18:16:29 | `vas-web-1-start` → HTTP 200。A6 は 18:19:12、A5 は 18:22:39 に回復 | |

### 3.8 T5: 権限を外して停止を実行（403）

| 時刻 | 事象 | 実行からの経過 |
|---|---|---|
| 18:16:38 | `grant_scheduler_permission=false` で Apply（インスタンス単位の IAM を 2 件削除） | |
| 18:18:07 | `vas-web-2-stop` を実行（IAM の削除から約 90 秒後） | 0 |
| 18:18:12 | `AttemptFinished` ERROR、`PERMISSION_DENIED`、HTTP 403、`debugInfo: URL_ERROR-ERROR_OTHER. Original HTTP response code number = 403` | +5 秒 |
| 18:18:56 | **S1** と **S3** が発報（S3 のラベル: `method=v1.compute.instances.stop`、`instance=…/vas-web-2`） | +49 秒 |
| 18:22:10 | **S2** 発報（`job_id=vas-web-2-stop`）→ 18:23:26 に回復 | +4 分 3 秒 |
| 18:23 頃 | 権限を戻す（Apply） | |

### 3.9 T6: 停止済みの VM にもう一度 stop

| 時刻 | 事象 |
|---|---|
| 18:24:04 | web-2 を stop（監査ログの last は 18:24:52） |
| 18:25:00 | 停止済みの web-2 にもう一度 stop → **HTTP 200**（冪等）。監査ログでは first が 18:25:02、last が 18:25:03 と、オペレーションが約 0.5 秒で完了 |
| 18:25:18 | **A7** 発報（no-op の stop でも監査ログに「完了」が記録されるため、A7 は発報する） |

### 3.10 T7: Compute のオペレーション自体が失敗するケース（API は受け付けたが VM の状態が変わらない）

- 意図的に起こす方法（ゾーンのリソース枯渇など）がないため、**再現していない**
- ただし S3 のフィルタ自体は、T4 と T5 の 403 に一致して発報したので、構文が正しいことと動作することは確認できた

---

## 4. 検知遅延のまとめ（実測値）

| 方式 | 対象 | 遅延 | 備考 |
|---|---|---|---|
| A1 ヘルスチェックログ（ログベースアラート） | アプリ停止 | **約 23 秒** | 同じラベルのインシデントが開いている間は、新しく発報しない |
| A3 ヘルスチェックのログベース指標 | アプリ停止 | 約 3.4〜3.7 分 | |
| A2 5xx ログ | 全台停止 / アプリ停止直後 | （参考値のみ） | ポリシー更新の直後のため、正確な値は取れていない |
| A4 プライベート Uptime Check | 全台停止 | 約 2 分 10 秒（最初の 503 から） | 60 秒間隔、条件の継続時間 60 秒 |
| A5 uptime の途絶 | VM 停止 | 約 8.7 分 | 条件の継続時間は 180 秒 |
| A6 バックエンド別リクエスト数の途絶 | VM 停止 / アプリ停止 | 約 5.9〜6.9 分 | 条件の継続時間は 180 秒。常時トラフィックが前提 |
| A7 監査ログの stop 完了 | VM 停止 | **約 1 分 16 秒**（停止完了から約 26 秒） | 計画停止や no-op の停止でも発報する |
| S1 Scheduler の ERROR ログ | API の失敗 | **約 35〜49 秒** | |
| S2 Scheduler のログベース指標 | API の失敗 | 約 3.4〜4 分 | |
| S3 監査ログの ERROR | API の失敗 / オペレーションの失敗 | 約 20〜49 秒 | |

---

## 5. 未検証・残った課題

- **通知メールが届いたかは、こちらからは確認していない**（受信箱が見られないため）。インシデントが作られたことは API で確認した。実際に届いたかどうかは、`miumosh@gmail.com` の受信箱で確認してほしい
- T7（オペレーションの失敗）は再現していない
- A2 の正確な検知遅延は取れていない（ポリシー更新の直後だったため）
- Datadog 側は実装も検証もしていない。指標名やタグは GCP 側で確かめたものをサンプルに反映したが、Datadog での名前の付き方（タグへの変換など）は未確認
