# 作業の時系列（cas-cert-lb 検証）

> 実施日: 2026-11-28。時刻は UTC（括弧内は JST = UTC+9）。
> 出典: リソースの `createTime` / `creationTimestamp`、CAS の監査ログ（管理アクティビティ）、各コマンドのログ（`logs/`。実体は Git 管理外）。
> 「頃」が付いた時刻は、コマンドを実行した時刻からの推定。

## 1. Terraform apply（47 リソース、所要 2 分 44 秒）

開始 05:38:07（14:38:07）／完了 05:40:51（14:40:51）

| 時刻（UTC） | 経過 | 出来事 | 補足 |
|---|---|---|---|
| 05:38:07 | 0:00 | `terraform apply tfplan` 開始 | |
| 05:38:10 | 0:03 | CA プール 3 つ作成（root-pool, sub-pool-tokyo, sub-pool-osaka）、VPC `vpc-main` 作成 | 監査ログ `CreateCaPool` |
| 05:38:11 | 0:04 | ルート CA `root-ca` の作成開始 | `CreateCertificateAuthority` |
| 05:38:22 | 0:15 | `root-ca` 有効化（ENABLED）、限定公開ゾーン `zone-sample` 作成 | `EnableCertificateAuthority`。ルート CA は作成から約 11 秒で有効 |
| 05:38:23〜24 | 0:16 | 下位 CA `sub-ca-osaka` / `sub-ca-tokyo` の作成開始 | |
| 05:38:34〜35 | 0:27 | ルート CA が、下位 CA 2 つの CA 証明書を発行 | 大阪の下位 CA も、東京の root-pool から発行された（**リージョンをまたぐ発行元の指定が可能**） |
| 05:38:35〜36 | 0:28 | 下位 CA 2 つを有効化（Activate → Enable） | 下位 CA は作成から約 12 秒で有効 |
| 05:38:37 | 0:30 | 発行構成 `ic-tokyo` / `ic-osaka` 作成 | |
| 05:38:47〜48 | 0:40 | クライアント VM `drtest-client-tk` / `drtest-client-os` 作成 | |
| 05:38:48 | 0:41 | 証明書 `cert-tokyo` / `cert-osaka` 作成（状態は PROVISIONING） | Terraform は発行完了を待たずに次へ進む |
| 05:39:10〜12 | 1:03 | 業務サーバ 4 台（MIG）作成 | |
| 05:39:33 | 1:26 | クライアント VM の startup-script 完了（dnsutils の導入、/tmp/root.pem の配置） | シリアルポートのログ |
| 05:40:05 | 1:58 | ターゲット HTTPS プロキシ `proxy-tokyo` / `proxy-osaka` 作成（11 秒） | **証明書がまだ PROVISIONING でもプロキシに設定できた** |
| 05:40:16 | 2:09 | 転送ルール `fr-tokyo` / `fr-osaka` の作成開始（31〜32 秒） | |
| 05:40:48 頃 | 2:41 | DNS レコード `test.sample.com.`（フェイルオーバー）作成（3 秒） | |
| 05:40:51 | 2:44 | apply 完了 | |

## 2. 証明書の発行待ち

| 時刻（UTC） | 出来事 | 補足 |
|---|---|---|
| 05:41:19 | T01〜T03 を実行。両方の証明書が PROVISIONING | `provisioningIssue: AUTHORIZATION_ISSUE`「Permission denied for issuing certificates from the configured CA Pool.」 |
| 05:41 頃 | CA プールの IAM を確認 → Certificate Manager のサービスエージェントに `roles/privateca.certificateRequester` は付与済み | **IAM の反映待ち**と判断し、30 秒おきに状態を確認 |
| 05:43:57 | `cert-tokyo` 発行（ACTIVE） | 証明書の作成から **5 分 9 秒** |
| 05:45:53 | `cert-osaka` 発行（ACTIVE） | 証明書の作成から **7 分 5 秒** |

- 作成直後に出る `AUTHORIZATION_ISSUE` は、IAM が反映されるまでの一時的なもので、待てば自動で発行された。何もしなくてよい。
- 後で作った `neg-cert-global-cas` は、作成（05:50:02）から **23 秒**で発行された（IAM の反映が終わった後だったため）。

## 3. クライアント VM への接続（つまずいた点）

| 時刻（UTC） | 出来事 | 補足 |
|---|---|---|
| 05:46 頃 | `gcloud compute ssh --tunnel-through-iap` が失敗（`Permission denied (publickey)`） | |
| 05:46 頃 | **gcloud が、プロジェクト全体のメタデータ `ssh-keys` に利用者の公開鍵を自動で追加した** | 「Updating project ssh metadata...」。プロジェクト全体の変更。後片付けで扱いを確認する |
| 05:46:33 | VM 上でユーザーが作られた（ゲストエージェント） | それでも接続できなかった |
| 05:47 頃 | 原因：利用者の秘密鍵 `~/.ssh/google_compute_engine` にパスフレーズが付いていて、ssh-agent もないため、対話できないシェルからは使えない | `ssh_askpass: exec(/usr/bin/ssh-askpass): No such file or directory` |
| 05:48 頃 | 検証専用のパスフレーズなしの鍵を scratchpad に作り、Terraform で**クライアント VM のインスタンスメタデータにだけ**登録（`client_ssh_public_key`。2 リソースを変更） | プロジェクト全体には登録しない |
| 05:49:16 | 接続できた | |

## 4. テストの実施

| 時刻（UTC） | テスト | 結果 |
|---|---|---|
| 05:41:19 | T01〜T03 | T01 OK、T02 は発行待ち（→ 05:45:53 に OK）、T03 は指示書の `--format` では null（API では `sslCertificates` に入っている） |
| 05:49:16〜18 | T04〜T08（両方の VM） | すべて OK |
| 05:49 頃 | T13〜T15（読み取り） | 記録済み |
| 05:49:47 | P1：`neg-cert-global-sm`（グローバル、セルフマネージド）作成 | 成功 |
| 05:49:53 | P2：`neg-ic-global`（グローバルの発行構成 → 東京の CA プール）作成 | **成功**（グローバルの発行構成からは、リージョンの CA プールを指定できる） |
| 05:50:02 | P2：`neg-cert-global-cas` 作成 → 05:50:25 に ACTIVE | 成功 |
| 05:50:10 頃 | N01・N02（gcloud） | エラー。ただし gcloud が URL を壊していた（§6 を参照） |
| 05:50:15 | N03：`neg-map` / `neg-entry` 作成 → プロキシ作成はエラー | 想定どおり |
| 05:50:20 頃 | N04 / N05 | どちらもエラー。想定どおり |
| 05:50:38 | N01・N02（Compute API 直接）→ エラー、N06 対照（API 直接）→ `neg-proxy-ok-api` 作成 | 想定どおり |
| 05:50:50 | N06（指示書どおりのフルパス）→ エラー、N06b（短い名前）→ `neg-proxy-ok2` 作成 | 指示書のコマンドに問題あり |
| 05:52 頃 | N01（Terraform 版、`neg-tf/`）→ apply でエラー | 想定どおり |
| 06:01:24〜27 | T09：DNS のプライマリを大阪に（設計書の gcloud コマンド、3 秒） | 06:01:28 に両方の VM で 10.20.0.10。TLS 検証 OK |
| 06:05:09〜11 | T10：DNS のプライマリを東京に戻す | 06:05:12 に 10.10.0.10。`terraform plan` は No changes |
| 06:06:29 | T11：東京の MIG をサイズ 0 に | 06:06:55 から HTTP 503。DNS は東京のまま |
| 06:06〜06:12 | T11：30 秒おきに dig / curl を記録（6 分間） | 自動切替なし。`get-health` は HEALTHY のまま |
| 06:12:32 | T11：MIG が東京の VM 2 台の削除を開始 | 接続ドレイン（300 秒）の後 |
| 06:13:24 | T11：東京の MIG をサイズ 2 に戻す | 06:14:17 に HEALTHY、HTTP 200 |
| 06:14:27 | T12：ルート CA を無効化（DISABLED） | |
| 06:14:31〜33 | T12：大阪で drtest-cert-osaka2 を作成 → 06:14:33 に発行 | ルート CA は DISABLED のまま |
| 06:15:07 | T12：ルート CA を有効化（ENABLED） | |
| 06:15:10 | T12：drtest-cert-osaka2 を削除 | `terraform plan` は No changes |

## 5. 後片付け

| 時刻（UTC） | 作業 | 結果 |
|---|---|---|
| 06:19:55 | `neg-proxy-ok-api`、`neg-proxy-ok2` を削除 | `um-tokyo` を参照しているので、destroy の前に削除した |
| 06:19:59〜06:20:02 | `neg-entry` → `neg-map` を削除 | |
| 06:20:07〜06:20:10 | `neg-cert-global-sm`、`neg-cert-global-cas` を削除 | |
| 06:20:13 | `neg-ic-global` を削除 | |
| 06:20:37 | `terraform destroy` 開始 | |
| 06:21:39〜41 | CA 3 つを無効化 → 削除（猶予期間なし） | 監査ログ。CA が存在したのは約 43.5 分 |
| 06:21:40〜44 | CA プール 3 つを削除 | |
| 06:23:36 | `terraform destroy` 完了（47 件、2 分 59 秒） | |
| 06:23:45 | 残っていないことを確認 | どれも 0 件。VPC は `default` だけ（検証前からあったもの） |
| 06:24:11 | プロジェクトのメタデータから `ssh-keys` を削除 | gcloud が 05:46 頃に自動で追加した鍵 1 本だけだった。プロジェクトは元の状態に戻った |
| 06:24 頃 | scratchpad の `neg.key` / `neg.crt` / `drtest-key` を削除、`terraform.tfvars` から `client_ssh_public_key` を削除 | |

## 6. N01・N02・N06 で分かったこと（gcloud の挙動）

regional のプロキシに対して `--certificate-manager-certificates` にフルパスを渡すと、gcloud はそれを「証明書の名前」とみなし、`--region` のリージョンの URL を前に付け足す。

```
指定した値: projects/P/locations/global/certificates/neg-cert-global-sm
gcloud が送った値: https://certificatemanager.googleapis.com/v1/projects/P/locations/asia-northeast1/certificates/projects/P/locations/global/certificates/neg-cert-global-sm
```

- このため、gcloud で試した N01・N02 のエラーは「グローバル証明書だから」ではなく「URL が壊れているから」出たもので、**設計の根拠にはならない**。
- 同じ理由で、指示書どおりの N06（同じリージョンの証明書をフルパスで指定）も失敗した。短い名前（`cert-tokyo`）なら成功する。
- 正しい URL を API に直接渡した場合と Terraform の場合は、本来の理由で拒否された：`Resource '...locations/global/certificates/...' must be in same scope as resource referencing it.`
