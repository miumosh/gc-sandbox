# 検証指示書：グローバルなCA・証明書は、リージョナルな内部ALBに設定できないことの確認

あなたは Google Cloud の検証担当エンジニアです。設計書「東京・大阪 DR構成設計」では、「リージョナルLBを使う以上、CAS・Certificate Managerは全リージョナルでしか構成できない」と結論づけています。この結論を、**実際に失敗することを確かめる**ことで実証してください。

この検証は「エラーになることを確認する」ものです。エラーが出たら、それが期待どおりの結果です。

---

## 0. 守ること（最優先）

- 操作するのは、**`PROJECT_ID` で指定した検証用プロジェクトだけ**です。
- **本番用のプロキシ（proxy-tokyo など）は一切変更しないでください。** 検証には、必ず新しく作るテスト用のプロキシ（`neg-` で始まる名前）を使ってください。
- 作成するリソースには、名前の先頭に `neg-` を付けてください。
- 削除は、対象を一覧にして承認を得てから実行してください。
- エラーメッセージは、**省略や言い換えをせず、全文をそのまま記録**してください。この文面が、設計の根拠になります。
- 想定と違って**成功してしまった場合**も、そのまま記録して、すぐに人間に報告してください（設計を見直すきっかけになります）。成功してできたリソースは、承認を得てから削除してください。

## 1. 前提と変数

```bash
export PROJECT_ID="（検証用プロジェクトID）"
export R_TK="asia-northeast1"
export R_OS="asia-northeast2"
gcloud config set project $PROJECT_ID
```

前提として、次のリソースがすでにあるものとします（DR構成の検証用プロジェクトと同じ環境を想定しています）：
- 東京のリージョナル内部ALBで使っているURLマップ `um-tokyo`
- 東京のCAプール `sub-pool-tokyo`

これらがない場合は、テストを始める前に、最小構成で作ってよいか人間に確認してください。

## 2. 準備：比較用の「グローバル」証明書を2種類作る

### P1 グローバルのセルフマネージド証明書
CASの影響を切り離して、「グローバル証明書であること」だけを条件にするために使います。

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout neg.key -out neg.crt -subj "/CN=test.sample.com" \
  -addext "subjectAltName=DNS:test.sample.com"
gcloud certificate-manager certificates create neg-cert-global-sm \
  --certificate-file=neg.crt --private-key-file=neg.key
# --location を指定しないと global になる
gcloud certificate-manager certificates describe neg-cert-global-sm --format="value(name)"
```

### P2 グローバルのCAS証明書（グローバルの発行構成から発行）
```bash
gcloud certificate-manager issuance-configs create neg-ic-global \
  --ca-pool=projects/$PROJECT_ID/locations/$R_TK/caPools/sub-pool-tokyo
gcloud certificate-manager certificates create neg-cert-global-cas \
  --domains="test.sample.com" --issuance-config=neg-ic-global
```
- `managed.state` が `ACTIVE` になるまで待ち、その状態を記録してください。
- この準備の段階でエラーになった場合は、そのエラーを記録してください。グローバルの発行構成でも、このように東京のCAプールを指定できること自体が、確認すべき事実の1つです。

## 3. テストケース（どれも「エラーになる」ことを期待しています）

### N01 グローバルのセルフマネージド証明書を、リージョナル内部ALBのプロキシに設定する
```bash
gcloud compute target-https-proxies create neg-proxy-01 --region=$R_TK --url-map=um-tokyo \
  --certificate-manager-certificates=projects/$PROJECT_ID/locations/global/certificates/neg-cert-global-sm
```
- **期待結果**：エラーになる（リージョナルのプロキシには、同じリージョンの証明書しか設定できないため）。

### N02 グローバルのCAS証明書を、リージョナル内部ALBのプロキシに設定する
```bash
gcloud compute target-https-proxies create neg-proxy-02 --region=$R_TK --url-map=um-tokyo \
  --certificate-manager-certificates=projects/$PROJECT_ID/locations/global/certificates/neg-cert-global-cas
```
- **期待結果**：エラーになる。

### N03 証明書マップを、リージョナル内部ALBのプロキシに設定する
```bash
gcloud certificate-manager maps create neg-map
gcloud certificate-manager maps entries create neg-entry --map=neg-map \
  --hostname="test.sample.com" --certificates=neg-cert-global-sm
gcloud compute target-https-proxies create neg-proxy-03 --region=$R_TK --url-map=um-tokyo \
  --certificate-map=neg-map
```
- **期待結果**：エラーになる（gcloud自体がフラグを受け付けない場合も、APIがエラーを返す場合もあります。どちらの段階で拒否されたかを記録してください）。

### N04 CASのCAプールを「グローバル」に作る
```bash
gcloud privateca pools create neg-pool-global --location=global --tier=devops
```
- **期待結果**：エラーになる（CAプールはリージョンの指定が必須なため）。
- **注意：もし成功してしまった場合**、CAを作る前にすぐ人間に報告してください。CAを作ると料金がかかります。

### N05 大阪の発行構成から、東京のCAプールを参照する
```bash
gcloud certificate-manager issuance-configs create neg-ic-os-to-tk --location=$R_OS \
  --ca-pool=projects/$PROJECT_ID/locations/$R_TK/caPools/sub-pool-tokyo
```
- **期待結果**：エラーになる（CAプールと発行構成は同じリージョンにする必要があるため）。
- **成功してしまった場合**：続けて、その発行構成から大阪の証明書を作ってください（`--location=$R_OS --issuance-config=neg-ic-os-to-tk`）。発行されるかどうか（最終的に `ACTIVE` になるか `FAILED` になるか）まで確認して記録します。

### N06 対照実験：リージョナル証明書は設定できること
エラーになったのが、コマンドの書き方の誤りではなく、本当にリソースの種類が原因であることを示すために、正しい組み合わせで成功することを確認します。

```bash
gcloud compute target-https-proxies create neg-proxy-ok --region=$R_TK --url-map=um-tokyo \
  --certificate-manager-certificates=projects/$PROJECT_ID/locations/$R_TK/certificates/cert-tokyo
```
- **期待結果**：成功する。確認したら、`neg-proxy-ok` は承認を得てから削除してください。

### N07（任意）コンソール画面での確認
- コンソールで、リージョナル内部ALBの「フロントエンドの構成」→「証明書」の選択肢を開きます。
- **期待結果**：選択肢に、そのリージョンの証明書だけが表示され、グローバル証明書（neg-cert-global-sm / neg-cert-global-cas）は表示されない。
- 人間にスクリーンショットを撮ってもらうよう依頼してください。

## 4. 報告の形式

```markdown
# 検証結果：グローバルなCA・証明書はリージョナルALBに使えないことの確認（実施日：YYYY-MM-DD）
## 結論
- 設計書の結論（全リージョナルしか選べない）を裏付けたか：はい / いいえ（理由）

## 結果一覧
| ID | 内容 | 期待結果 | 実際の結果 | 判定 |
|---|---|---|---|---|
| N01 | グローバルのセルフマネージド証明書 → リージョナルのプロキシ | エラー | | |
| N02 | グローバルのCAS証明書 → リージョナルのプロキシ | エラー | | |
| N03 | 証明書マップ → リージョナルのプロキシ | エラー | | |
| N04 | グローバルのCAプール | エラー | | |
| N05 | 大阪の発行構成 → 東京のCAプール | エラー | | |
| N06 | 対照実験：リージョナル証明書 → リージョナルのプロキシ | 成功 | | |

## エラーメッセージ全文
### N01
（全文をそのまま貼る）
...

## 想定と違った点
## 後片付けの状況
```

## 5. 後片付け ※承認を得てから実行

`neg-` で始まるリソースを一覧にし、承認を得てから、次の順に削除してください：
1. プロキシ（neg-proxy-*）
2. 証明書マップのエントリ → 証明書マップ（neg-entry, neg-map）
3. 証明書（neg-cert-*）
4. 発行構成（neg-ic-*）
5. CAプール（neg-pool-global。万一作成されていた場合のみ）

最後に、ローカルに作った `neg.key` と `neg.crt` も削除してください。
