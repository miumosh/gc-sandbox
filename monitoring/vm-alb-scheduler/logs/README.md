# logs: 検証時に取得したログ（Git 管理外）

検証（[`../RESULTS.md`](../RESULTS.md)）の時間帯に出力された Cloud Logging のログと Cloud Monitoring のインシデントを、CLI で JSON に書き出して保存している。

- **Git で管理するのは `.gitignore`、`README.md`、`export-logs.sh` の 3 つだけ**。ログ本体（`<日時>/` 以下）は、プロジェクト ID、内部 IP、SA のメールアドレスなどを含むので Git 管理外にしている
- Cloud Logging の `_Default` バケットの保持期間は 30 日。期間を過ぎるとクラウド側では消えるので、このローカルの JSON が唯一の記録になる

## 取得済みのログ

`20261110T1710Z/`（対象期間: 2026-11-10 17:10:00Z〜18:35:00Z、プロジェクト `miumosh-sb-test01`）

| ファイル | 内容 | 件数 | フィルタ（期間の条件は省略） |
|---|---|---|---|
| `healthcheck.json` | ヘルスチェックログ（状態遷移） | 17 | `logName="projects/<P>/logs/compute.googleapis.com%2Fhealthchecks"` |
| `lb-request.json` | 内部 ALB のリクエストログ（試験クライアントからの 2 秒ごとのリクエスト ＋ Uptime Check） | 2,580 | `resource.type="internal_http_lb_rule" AND logName="projects/<P>/logs/loadbalancing.googleapis.com%2Frequests"` |
| `scheduler.json` | Cloud Scheduler の実行ログ（AttemptStarted / AttemptFinished） | 30 | `resource.type="cloud_scheduler_job"` |
| `audit-compute.json` | Compute の監査ログ（instances.start / stop。成功と 403 の両方） | 20 | `logName=".../cloudaudit.googleapis.com%2Factivity" AND protoPayload.methodName=~"compute\.instances\.(start\|stop)$"` |
| `audit-system-event.json` | Compute のシステムイベント監査ログ | 0 | `logName=".../cloudaudit.googleapis.com%2Fsystem_event"` |
| `monitoring-events.json` | アラートが開いた・閉じたときのイベントログ（ViolationOpenEventv1 / ViolationAutoResolveEventv1 など） | 58 | `logName=~"projects/<P>/logs/monitoring.googleapis.com%2FViolation"` |
| `incidents.json` | Monitoring API v3 `projects/<P>/alerts` のインシデント一覧（openTime / closeTime / ラベル） | 24 | – |

### メモ

- 内部 ALB のリクエストログのログ名は **`loadbalancing.googleapis.com%2Frequests`**。アラートのイベントログも同じ `resource.type="internal_http_lb_rule"` で記録されるので、ALB のログだけが欲しい場合は logName で絞る
- システムイベントが 0 件なのは、今回の停止がすべて API 経由（Scheduler）だったため
- インシデント一覧は、ポリシーを削除した後（destroy 後）も API で取得できた

## 再取得の方法

```bash
gcloud auth login
./export-logs.sh <PROJECT_ID> <START_UTC> <END_UTC> [OUT_DIR]
# 例
./export-logs.sh miumosh-sb-test01 2026-11-10T17:10:00Z 2026-11-10T18:35:00Z
```

出力先を省略すると、このディレクトリの下に `<開始日時>/`（例: `20261110T1710Z/`）を作って書き出す。

## 見方の例

```bash
cd 20261110T1710Z
# ヘルスチェックの状態遷移
jq -r '.[] | [.timestamp, .resource.labels.instance_group_name, .jsonPayload.healthCheckProbeResult.previousHealthState, .jsonPayload.healthCheckProbeResult.healthState, .jsonPayload.healthCheckProbeResult.detailedHealthState] | @tsv' healthcheck.json
# ALB の 200 以外の応答
jq -r '.[] | select(.httpRequest.status != 200) | [.timestamp, .httpRequest.status, .jsonPayload.proxyStatus, .resource.labels.backend_name] | @tsv' lb-request.json
# Scheduler の実行結果
jq -r '.[] | select(.jsonPayload["@type"] | endswith("AttemptFinished")) | [.timestamp, .resource.labels.job_id, .severity, .httpRequest.status, .jsonPayload.status] | @tsv' scheduler.json
# インシデント
jq -r '.alerts[] | [.openTime, .closeTime, .policy.displayName] | @tsv' incidents.json
```
