# 監視設計の推奨と、月次メンテナンス（Scheduler による VM 停止・起動）時の監視方針

検証結果（[`RESULTS.md`](RESULTS.md)、[`KNOWLEDGE.md`](KNOWLEDGE.md)）をもとに、本番運用で何を監視するか、月次メンテナンスの間は何を静観し何を注視するかをまとめる。

- 前提とする運用: 内部 ALB 配下で VM 2 台が **常時稼働**（冗長構成）。Cloud Scheduler で **月に 1 回** VM を停止して起動するメンテナンスを行う
- 表の「根拠」列: **検証済み** = 今回の検証で動作を確認したもの。**未検証** = 推奨するが今回は試していないもの
- ID（A1〜A7、S1〜S3）は README と RESULTS のものと同じ

---

## 1. 常時監視の推奨セット

### 1.1 何を検知したいか

| # | 検知したい事象 | 影響 | 重要度 |
|---|---|---|---|
| E1 | サービス全体の停止（2 台とも応答しない） | 利用者に影響あり | **Critical** |
| E2 | 1 台が止まり、冗長性が失われた（VM 停止、またはアプリ停止） | 利用者への影響はないが、あと 1 台止まれば全停止 | **Warning** |
| E3 | 計画外の VM 停止（手動操作など） | E2 の原因を特定する | Warning / Info |
| E4 | Scheduler による起動・停止の失敗 | メンテナンスの失敗。起動の失敗なら E2 や E1 につながる | **Error** |

### 1.2 採用を推奨する監視

| 優先度 | ID | リソース種別 | 監視項目 | 閾値概要 | 閾値詳細 | 検知する事象 | 遅延（実測） | 重要度 | 根拠 | 採用する理由 |
|---|---|---|---|---|---|---|---|---|---|---|
| ★★★ | **A4** | Cloud Load Balancing（内部 ALB）| Uptime Check の結果（内部 VIP への HTTP 外形監視） | 6 拠点から 60 秒ごとにチェックし、失敗した拠点が 2 つ以上の状態が 60 秒続いたら発報 | チェック間隔 60 秒 / タイムアウト 10 秒 / HTTP GET `/`:80 / 6 拠点（VPC チェッカー）<br>集計: 60 秒（`ALIGN_NEXT_OLDER` → `REDUCE_COUNT_FALSE`）<br>条件: 失敗拠点数 **> 1**、継続時間 **60 秒**<br>自動クローズ 30 分 | E1 | 約 2 分 | Critical | 検証済み | 利用者から見た可用性を直接見られる。トラフィックの有無に左右されない |
| ★★★ | **A2** | Cloud Load Balancing（内部 ALB）| ALB のリクエストログ | 5xx のログが 1 件出たら発報 | 条件: `httpRequest.status >= 500` のログ **1 件以上**<br>通知間隔の下限 **5 分**（`notification_rate_limit=300s`）<br>自動クローズ **30 分**（`auto_close=1800s`）<br>抽出ラベル: `backend_name`（推奨） | E1（＋アプリ停止直後の 503） | 1 分以内（推定） | Critical | 検証済み（遅延は参考値） | 実際の利用者のエラーを拾える。A4 の補完 |
| ★★★ | **A1** | Cloud Load Balancing（内部 ALB）| ヘルスチェックログ | VM が HEALTHY から UNHEALTHY に変わったログが 1 件出たら発報（5 秒間隔のチェックで 2 回連続失敗すると UNHEALTHY） | ヘルスチェック: 間隔 **5 秒** / タイムアウト **5 秒** / UNHEALTHY 判定 **2 回連続失敗** / HEALTHY 判定 **2 回連続成功**<br>条件: 遷移ログ **1 件以上**<br>通知間隔の下限 **5 分** / 自動クローズ **30 分**<br>抽出ラベル: `ip_address`, `detailed_state` | E2（アプリ停止・ハング） | **約 23 秒** | Warning | 検証済み | 最も速い。ただし **VM 停止は拾えない** ので A5 と組み合わせる |
| ★★★ | **A5** | Compute Engine | VM の稼働時間指標（uptime） | 指標が 3 分間途絶えたら発報（VM ごと） | 集計: **60 秒**ごとに `ALIGN_MEAN`、`instance_name` ごと<br>条件: データ欠損が **180 秒**続く<br>自動クローズ **30 分** | E2（VM 停止） | 約 8.7 分 | Warning | 検証済み | VM 停止を確実に拾える。トラフィックの有無に左右されない |
| ★★★ | **S1** | Cloud Scheduler | ジョブの実行ログ | 実行失敗（ERROR）のログが 1 件出たら発報 | 条件: ERROR ログ **1 件以上**<br>ジョブ側: `retry_count=0` / `attempt_deadline=60s`<br>通知間隔の下限 **5 分** / 自動クローズ **30 分**<br>抽出ラベル: `job_id`, `status` | E4（API の失敗） | 約 35〜49 秒 | Error | 検証済み | 速い。どのジョブが、なぜ失敗したか（`job_id` / `status`）が分かる |
| ★★★ | **S3** | Compute Engine | 監査ログ（管理アクティビティ） | VM の起動・停止操作のエラーログが 1 件出たら発報 | 条件: ERROR ログ **1 件以上**<br>通知間隔の下限 **5 分** / 自動クローズ **30 分**<br>抽出ラベル: `method`, `instance` | E4（API の失敗、オペレーションの失敗） | 約 20〜49 秒 | Error | 検証済み（オペレーション失敗は未再現） | Scheduler からは「成功」に見える起動失敗（リソース枯渇など）を拾える唯一の手段 |
| ★★ | **A7'** | Compute Engine | 監査ログ（管理アクティビティ） | VM 停止の完了ログが 1 件出たら発報（Scheduler による停止は除く） | 条件: 停止完了ログ（`operation.last=true`）**1 件以上**、Scheduler の SA を除外<br>通知間隔の下限 **5 分** / 自動クローズ **30 分**<br>抽出ラベル: `instance`, `principal` | E3（計画外の停止） | 約 1 分 | Warning | 検証済み（除外条件は未検証） | 誰が止めたかが分かる。除外しておけば、メンテナンスで誤検知しない |
| ★★ | **A8** | Compute Engine | 監査ログ（システムイベント） | 基盤障害や OS 内からのシャットダウンなどのログが 1 件出たら発報 | 条件: 該当ログ **1 件以上**<br>通知間隔の下限 **5 分** / 自動クローズ **30 分**（他のログアラートと同じ想定） | E3（基盤障害や OS 内からのシャットダウン） | – | Warning | **未検証** | API 操作によらない停止は A7 では拾えないので、その補完 |
| ★ | A6 | Cloud Load Balancing（内部 ALB）| バックエンドごとのリクエスト数指標 | 特定のバックエンド（VM）へのリクエストが 3 分間途絶えたら発報 | 集計: **60 秒**ごとに `ALIGN_SUM`、`backend_name` ごと（空は除く）<br>条件: データ欠損が **180 秒**続く<br>自動クローズ **30 分**<br>前提: 常時トラフィック（検証では 2 秒間隔） | E2（VM 停止とアプリ停止の両方） | 約 6〜7 分 | Warning | 検証済み | ALB の観点では最も素直だが、**常時トラフィックが前提**。夜間などトラフィックが途切れる環境では誤検知するので、採用はトラフィック次第 |
| ★ | S2 | Cloud Scheduler | ジョブ失敗数の指標（実行ログから作るログベース指標） | 1 分間の失敗数が 1 以上になったら発報（ジョブごと） | 集計: **60 秒**ごとに `ALIGN_SUM` → `REDUCE_SUM`、`job_id` ごと<br>条件: **> 0**、継続時間 **0 秒**（即時）<br>自動クローズ **30 分** | E4 | 約 3.4〜4 分 | – | 検証済み | S1 と同じ事象を遅れて検知するだけ。ダッシュボードや Datadog 連携が必要な場合だけ使う |
| ★ | A3 | Cloud Load Balancing（内部 ALB）| UNHEALTHY 遷移数の指標（ヘルスチェックログから作るログベース指標） | 1 分間の遷移数が 1 以上になったら発報 | 集計: **60 秒**ごとに `ALIGN_SUM` → `REDUCE_SUM`<br>条件: **> 0**、継続時間 **0 秒**（即時）<br>自動クローズ **30 分** | E2（アプリ停止） | 約 3.4〜3.7 分 | – | 検証済み | A1 と同じ事象を遅れて検知するだけ。ダッシュボードや Datadog 連携が必要な場合だけ使う |
| – | S4 | Cloud Scheduler | Scheduler 自身が出す指標 | – | – | – | – | – | 存在しない | 使えない |

**最小構成（★★★ のみ）: A4 + A2 + A1 + A5 + S1 + S3**
- E1: A4 と A2
- E2: A1（アプリ停止）と A5（VM 停止）
- E4: S1 と S3

#### 1.2.1 実装上の詳細（Cloud Monitoring で設定する値）

| ID | 監視の種類 | Monitoring のリソースタイプ | 指標名 / ログ名 | 条件（フィルタ・集計） | その他の設定 |
|---|---|---|---|---|---|
| A4 | 指標アラート | `servicedirectory_service` | `monitoring.googleapis.com/uptime_check/check_passed`（`check_id` で絞る） | `ALIGN_NEXT_OLDER` / `REDUCE_COUNT_FALSE`（60 秒）> 1 が 60 秒続く | チェック: HTTP GET `/`:80、60 秒間隔、タイムアウト 10 秒、`VPC_CHECKERS`。転送ルールに `allow_global_access=true` が必要 |
| A2 | ログベースアラート | `internal_http_lb_rule` | ALB のリクエストログ | `resource.labels.forwarding_rule_name="<FR名>"` かつ `httpRequest.status>=500` | 通知は 5 分に 1 回まで、自動クローズ 30 分。`backend_name` をラベルとして抽出（推奨） |
| A1 | ログベースアラート | `gce_instance_group` | `compute.googleapis.com/healthchecks` | `healthCheckProbeResult.healthState="UNHEALTHY"` かつ `previousHealthState="HEALTHY"` | ヘルスチェック: 5 秒間隔、タイムアウト 5 秒、2 回失敗で UNHEALTHY。`ip_address` / `detailed_state` を抽出 |
| A5 | 指標アラート（データ欠損） | `gce_instance` | `compute.googleapis.com/instance/uptime` | `instance_name` ごと、60 秒の `ALIGN_MEAN`、180 秒途絶 | – |
| S1 | ログベースアラート | `cloud_scheduler_job` | Scheduler の実行ログ | `jsonPayload.@type=…AttemptFinished` かつ `severity>=ERROR` | ジョブ側は `retry_count=0`。`job_id` / `status` を抽出 |
| S3 | ログベースアラート | `gce_instance` | `cloudaudit.googleapis.com/activity` | `methodName=~"compute\.instances\.(start\|stop)$"` かつ `severity>=ERROR` | `method` / `instance` を抽出 |
| A7' | ログベースアラート | `gce_instance` | `cloudaudit.googleapis.com/activity` | `methodName=~"compute\.instances\.stop$"` かつ `operation.last=true` かつ `NOT principalEmail="<SchedulerのSA>"` | `instance` / `principal` を抽出 |
| A8 | ログベースアラート | `gce_instance` | `cloudaudit.googleapis.com/system_event` | `methodName=~"compute\.instances\.(hostError\|guestTerminate\|preempted\|automaticRestart)$"` | 未検証 |
| A6 | 指標アラート（データ欠損） | `internal_http_lb_rule` | `loadbalancing.googleapis.com/https/internal/backend_request_count` | `forwarding_rule_name` で絞り、`backend_name` ごと（空は除く）、60 秒の `ALIGN_SUM`、180 秒途絶 | 常時トラフィックが前提 |
| S2 | 指標アラート | `cloud_scheduler_job` | `logging.googleapis.com/user/<prefix>_scheduler_failed_count` | `job_id` ごと、60 秒の `ALIGN_SUM` > 0、継続時間 0 秒 | 元のログフィルタは S1 と同じ |
| A3 | 指標アラート | `global`（※） | `logging.googleapis.com/user/<prefix>_hc_unhealthy_count` | 60 秒の `ALIGN_SUM` > 0、継続時間 0 秒 | 元のログフィルタは A1 と同じ |

※ ヘルスチェックログのリソースタイプ `gce_instance_group` は Monitoring に存在しないため、そこから作るログベース指標は `global` になる。

ログベースアラートの共通設定: 通知は 5 分に 1 回まで、自動クローズ 30 分。

### 1.3 検証結果から反映すべき設定の改善

| 対象 | 改善内容 | 理由 |
|---|---|---|
| A1 | `previousHealthState="HEALTHY"` の条件を必ず入れる | ないと起動のたびに誤検知する（検証済み） |
| A2 | `label_extractors` で `backend_name` を抽出する | ラベルがないと、全事象が 1 つのインシデントにまとめられ、2 回目以降の 5xx が通知されない（検証済み） |
| ログベースアラート全般 | 事象を識別するラベル（`job_id` / `ip_address` / `instance`）を抽出する。`auto_close` は 30 分程度 | 同じラベルのインシデントが開いている間は、新しく通知されない。タイマーも延びる（検証済み） |
| A7 | `NOT protoPayload.authenticationInfo.principalEmail="vas-scheduler@<P>.iam.gserviceaccount.com"` を加えて A7' とする | 計画停止を除外し、計画外の停止だけを通知する |
| 指標の条件 | `resource.type` を必ず指定する（ヘルスチェック由来のログベース指標は `global`） | 指定しないと Apply が失敗する（検証済み） |
| 内部 ALB | プライベート Uptime Check を使う場合は `allow_global_access=true` | ないとチェッカーが届かない（検証済み） |

### 1.4 A8（System Event）のフィルタ例（未検証）

```
logName="projects/<P>/logs/cloudaudit.googleapis.com%2Fsystem_event"
resource.type="gce_instance"
protoPayload.methodName=~"compute\.instances\.(hostError|guestTerminate|preempted|automaticRestart)$"
```

- API を経由しない停止（基盤障害、OS 内から shutdown、自動再起動など）を拾うためのもの。method 名の一覧は、導入前に実際のログで確かめること

### 1.5 通知先の分け方の例

| 重要度 | 対象 | 通知先 |
|---|---|---|
| Critical | A4, A2 | オンコール（電話、Slack のメンション） |
| Error | S1, S3 | 運用チャネル（すぐ確認する） |
| Warning | A1, A5, A7', A8 | 運用チャネル（営業時間内に確認する） |
| Info | A7（Scheduler による停止。記録用）、S2 / A3 | ダッシュボードのみ |

---

## 2. 月次メンテナンス時の監視方針

### 2.1 メンテナンスの方式（推奨はローリング）

| 方式 | 内容 | サービスへの影響 | 推奨 |
|---|---|---|---|
| **ローリング** | web-1 を停止 → 起動 → **HEALTHY を確認してから** web-2 を停止 → 起動 | なし（常に 1 台は稼働） | **◎** |
| 同時 | 2 台を同時に停止 → 起動 | 停止から起動完了まで、サービス全体が止まる（検証では、起動の指示から HEALTHY まで約 50 秒） | 計画停止の告知ができる場合のみ |

**ローリングの注意点**: Scheduler は時刻どおりに実行されるだけで、「web-1 が HEALTHY に戻ったら web-2 を止める」といった条件判断はできない。web-1 の起動に失敗したまま web-2 の停止ジョブが動くと、**全台停止** になる。

対策（どれか 1 つ以上）:
1. web-1 の起動時刻から web-2 の停止時刻までに、十分な間隔（30 分以上）を空ける。その間に S1 / S3 / A5 が出たら、オペレーターが `gcloud scheduler jobs pause vas-web-2-stop` を実行する
2. 本番では、Scheduler から Cloud Workflows を呼び、「停止 → 起動 → ヘルス確認 → 次の VM」を順番に制御する（**未検証**）
3. メンテナンス前に、web-2 の停止ジョブを「起動が成功したら手動で resume する」運用にしておく

**月次 cron の注意**: unix-cron では、日（DOM）と曜日（DOW）を両方指定すると **OR 条件** になる（例: `0 2 1-7 * 0` は「毎月 1〜7 日、および毎週日曜」に実行される）。「第 1 日曜」のような指定は cron では書けないので、日付を固定する（例: `0 2 1 * *`）か、Workflows 側で曜日を判定する（**未検証**。Cloud Scheduler の仕様は導入前に確認すること）。

### 2.2 各アラートの扱い（静観するか、注視するか）

#### ローリング方式の場合

| ID | メンテナンス中の挙動（検証結果から予測） | 扱い | 理由 |
|---|---|---|---|
| **A5** VM の uptime 途絶 | 停止した VM について、停止から約 8〜9 分後に発報 → 起動から約 6 分後に回復 | **静観**（スヌーズ） | 想定どおりの発報 |
| **A6** バックエンド別リクエスト数の途絶 | 停止した VM の IG について約 7 分後に発報 → 起動後に回復 | **静観**（スヌーズ） | 想定どおりの発報 |
| **A7** 監査ログの stop 完了（除外条件なし） | Scheduler による stop で約 1 分後に発報 | **静観**（A7' にして、そもそも発報させない） | 想定どおりの発報 |
| **A1** UNHEALTHY 遷移 | **VM 停止では発報しない**（検証済み）。起動時も `previousHealthState` 条件があれば発報しない | **注視** | メンテナンス中に発報したら、**停止していない方の VM** でアプリが落ちている可能性がある |
| **A2** 5xx ログ | ローリングでも、**停止の瞬間に数件の 503 が出ることがある**（T1 の 2 回目で `connection_refused` が 1 件。1 回目はタイムアウトだけ） | **注視**（ただし停止直後の数件は許容） | 停止直後の単発の 503 は想定内。続く場合は、稼働中の VM にも問題がある。誤検知を避けたいなら、A2 を「1 分間に N 件以上」の指標アラートにするか、停止前に `capacity_scaler=0` で振り分けを止める（未検証） |
| **A4** Uptime Check | ローリングなら発報しない | **注視（最重要）** | 発報したら全台停止。web-2 の停止ジョブを止めるかどうか判断する |
| **S1** Scheduler の ERROR | 正常なら発報しない | **注視（最重要）** | 停止や起動の API 呼び出しが失敗した |
| **S3** 監査ログの ERROR | 正常なら発報しない | **注視（最重要）** | 特に **起動オペレーションの失敗**（リソース枯渇など）。Scheduler からは成功に見えるので、これが唯一の手がかり |
| A8 System Event | 発報しない想定 | 注視 | |

#### 同時方式の場合（上の表との差分）

| ID | 挙動 | 扱い |
|---|---|---|
| **A4** | 停止から約 2〜3 分後に発報 → 起動して HEALTHY になると約 2 分で回復 | **静観**（スヌーズ）。ただし時間内に回復するかは注視する |
| **A2** | 全台停止の間、503 が出続ける | **静観**（スヌーズ） |
| S1 / S3 | 変わらない | **注視（最重要）** |

### 2.3 スヌーズの範囲と時間

検証で実測した値（停止に約 50 秒、A5 の発報は停止から約 9 分後、A5 の回復は起動から約 6 分後、HEALTHY までは起動から約 50 秒）から、スヌーズの時間を決める。

```
スヌーズ開始 = 最初の停止ジョブの 5 分前
スヌーズ終了 = 最後の起動ジョブの 15 分後
対象 = A5, A6, A7（A7' にしているなら不要）、同時方式なら A4 と A2 も
対象外（絶対にスヌーズしない） = S1, S3, A1、ローリング方式なら A4 と A2
```

- **スヌーズ終了後も問題が残っていれば、通常どおり発報されることが「起動できなかった」ことの検知になる**。たとえば起動に失敗して VM が停止したままなら、スヌーズ終了後に A5 が発報する。そのため、スヌーズ時間を必要以上に長くしない
  - スヌーズ中に作られたインシデントが、スヌーズ終了後にどう扱われるか（すぐ通知されるか、条件を評価し直して新たに作られるか）は **未検証**。導入前に一度確かめること
- Cloud Monitoring のスヌーズは、ポリシー単位で期間を決めて作る（`gcloud monitoring snoozes create`）。毎月繰り返す設定はないので、メンテナンスの前に作るか、作成を自動化する（**未検証**）
- Datadog の場合は `datadog_downtime_schedule` で毎月繰り返すダウンタイムを設定し、`monitor_tags` で A5 / A6 / A7 だけを対象にする

### 2.4 「失敗を検知できない」ケースと補い方

| ケース | S1 / S3 で検知できるか | 補い方 |
|---|---|---|
| API の失敗（403、404 など） | ◯ S1, S3 | – |
| 起動オペレーションの失敗（リソース枯渇など） | ◯ S3（未再現） | スヌーズ終了後の A5、メンテナンス後の確認 |
| **ジョブが実行されなかった**（誤って一時停止した、削除した、スケジュールの設定ミス） | **×**（実行ログ自体が出ない） | メンテナンス後の確認で、ジョブの `lastAttemptTime` と VM の起動時刻を確かめる |
| 起動はしたがアプリが立ち上がらない | ×（Scheduler と Compute は成功している） | **A1 は起動時には発報しない**（HEALTHY を経由しないため）。A5 も回復してしまう。**A6**（トラフィックがあれば）、またはメンテナンス後の `get-health` で確認する |
| 停止は成功したが、予定外の時刻だった | × | A7（記録用）の時刻で確認する |

→ 監視だけでは「起動したがアプリが UNHEALTHY のまま」と「ジョブが未実行」を確実には拾えない。**メンテナンス後の確認手順（2.5）を必ず実施する**。

### 2.5 メンテナンス当日の手順

#### 事前確認（開始 30 分前）

```bash
P=<project>; R=asia-northeast1
# 1. 2 台とも HEALTHY であること（片方が UNHEALTHY なら、ローリングでも全停止になるので中止）
gcloud compute backend-services get-health vas-bes --region $R --project $P \
  --format='value(status.healthStatus[].instance.basename(),status.healthStatus[].healthState)'
# 2. 開いているインシデントがないこと
gcloud monitoring policies list --project $P --format='value(displayName,enabled)'
curl -s -G -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://monitoring.googleapis.com/v3/projects/$P/alerts" --data-urlencode 'filter=state="OPEN"'
# 3. ジョブが ENABLED で、スケジュールと時刻が正しいこと
gcloud scheduler jobs list --location $R --project $P --format='table(ID,STATE,SCHEDULE,timeZone)'
# 4. 対象 VM に Scheduler の SA の権限があること（T5 の 403 を防ぐ）
gcloud compute instances get-iam-policy vas-web-1 --zone asia-northeast1-a --project $P
# 5. スヌーズを作成する（2.3 の範囲と時間で）
```

#### メンテナンス中（ローリングの例）

| 時刻（例） | 出来事 | 確認すること |
|---|---|---|
| 02:00 | web-1 停止ジョブ | 1 分以内に S1 / S3 が出ていないこと。A4 が正常のままであること |
| 02:10 | web-1 起動ジョブ | 1 分以内に S1 / S3 が出ていないこと。**約 1 分で web-1 が HEALTHY になること**（`get-health`） |
| 02:10〜02:40 | 判断ポイント | web-1 が HEALTHY でなければ、**`gcloud scheduler jobs pause vas-web-2-stop` を実行して web-2 の停止を中止** |
| 02:40 | web-2 停止ジョブ | web-1 の場合と同じ |
| 02:50 | web-2 起動ジョブ | web-1 の場合と同じ |

#### 事後確認（最後の起動から 15 分後、スヌーズ終了時）

```bash
# 1. 2 台とも HEALTHY
gcloud compute backend-services get-health vas-bes --region $R --project $P ...
# 2. すべてのジョブが今回実行され、成功（200）していること（未実行の検知）
gcloud logging read 'resource.type="cloud_scheduler_job" AND jsonPayload."@type"="type.googleapis.com/google.cloud.scheduler.logging.AttemptFinished" AND timestamp>="<開始時刻>"' \
  --project $P --format='value(timestamp,resource.labels.job_id,severity,httpRequest.status)'
# 3. start と stop のオペレーションが完了（operation.last）し、ERROR がないこと
gcloud logging read 'logName="projects/'$P'/logs/cloudaudit.googleapis.com%2Factivity" AND protoPayload.methodName=~"compute.instances.(start|stop)" AND timestamp>="<開始時刻>"' \
  --project $P --format='value(timestamp,protoPayload.methodName,protoPayload.resourceName,severity,operation.last)'
# 4. メンテナンス中に 5xx が出ていないこと（ローリングの場合）
gcloud logging read 'resource.type="internal_http_lb_rule" AND httpRequest.status>=500 AND timestamp>="<開始時刻>"' --project $P --limit 20
# 5. スヌーズが終了し、A5 / A6 が発報していないこと（発報していれば、起動の失敗を疑う）
```

### 2.6 メンテナンス全体の流れ（ローリング）

```
         02:00 web-1 stop   02:10 web-1 start    02:40 web-2 stop   02:50 web-2 start   03:05
スヌーズ  |<----------------------------------------------------------------------------->|
 A5/A6/A7  発報 → 静観 ………… 回復                  発報 → 静観 ………… 回復             （終了後に残っていれば発報）
 S1/S3     ■ 注視（失敗したら即対応） ■ 注視              ■ 注視              ■ 注視
 A1/A2/A4  ■ 注視（発報 = 稼働中のもう 1 台に異常）  ……………………………………………………
 判断                       └ web-1 が HEALTHY でなければ web-2 stop を pause
 事後確認                                                                              ■ 2.5 の手順
```

---

## 3. まとめ

- **常時監視**: A4（Uptime）+ A2（5xx）で全停止を、A1（アプリ停止）+ A5（VM 停止）で 1 台停止を、S1 + S3 で Scheduler の失敗を拾う。A7 は Scheduler の SA を除外して、計画外の停止の検知に使う
- **メンテナンス中に静観するもの**: VM の停止そのものに反応する **A5 / A6 / A7**（同時方式なら A4 / A2 も）。スヌーズで抑止する
- **メンテナンス中に注視するもの**: **S1 / S3**（停止・起動の失敗）と、ローリングなら **A4 / A2 / A1**（稼働中のもう 1 台の異常）
- **監視では拾えないもの**（ジョブの未実行、起動後のアプリ不調）は、**事後確認の手順** で補う
- 未検証の項目（A8、A7 の除外条件、スヌーズ終了後の挙動、Workflows による制御、月次 cron の書き方）は、本番に入れる前に確認すること
