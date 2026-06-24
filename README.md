# bat-bootstrap

BAT サーバー自動構築の **入口スクリプト `bootstrap.sh` を公開配布するためのリポジトリ**。

本番サーバー（Xserver VPS 等）に root で SSH 到達した状態から、対話形式で
OS 設定・SSH 二段階認証（公開鍵＋TOTP）・Docker・BunkerWeb(WAF) までを自動構築する。

- 本リポジトリは **公開**。機密情報は一切含まない。
- アプリ本体（`bat-app` の fork）は **private** のままとし、`bootstrap.sh` が対話で受け取った認証情報（Deploy key / PAT）で clone する。
- 詳細手順は設計資料 **BAT_サーバー構築手順書.docx**（`bat-doc/docs/詳細設計/`）を参照。

## 使い方（本番 VPS で）

root で SSH 接続後、以下を実行する。

```bash
# 1) OS を最新化してから再起動
#    ※ カーネル更新を確実に反映させるため、bootstrap.sh 取得前に必ず実施する
dnf -y update
reboot
```

再起動後、再度 root で SSH 接続し直してから続行する。

```bash
# 2) bootstrap.sh を取得
#    ※ "curl ... | bash" は対話入力(read)が壊れるため、必ず保存してから実行する
curl -fsSL https://raw.githubusercontent.com/nextcode-bat/bat-bootstrap/main/bootstrap.sh -o bootstrap.sh

# 3) 実行
sudo bash bootstrap.sh
```

対話で順に質問される（続行確認／リポURL／clone認証／配置先／環境／ドメイン／メール・DBパス／SSHユーザー・公開鍵）。
完了すると BunkerWeb 経由で HTTPS アクセスできる状態になる。

```bash
# 4) 初回ユーザー（管理者）を作成
#    /register ルートは存在しない設計のため、初回ユーザーは必ず本コマンドで作成する。
#    対話で email / username / パスワードを入力する。
#      - username: 3〜64文字・英数字・ハイフン・アンダースコア
#      - password: 12文字以上・英大文字・英小文字・数字・記号を各1文字以上
#                  （BAT_セキュリティ要件 認証-02 準拠）
#    既にユーザーが1件でも存在する場合は失敗する（1人運用ガード）。
#    なお、migrate および db:seed は Ansible app_deploy ロールで自動実行済みのため、
#    ここでは追加の手動投入は不要。
cd /opt/bat-app   # bootstrap.sh の対話で別パスを指定した場合はそちらへ
sudo docker compose exec app php artisan bat:create-user
```

作成直後は 2FA 未設定（`totp_enabled_at = null`）。
ブラウザで `https://<SERVER_NAME>/login` にユーザー名・パスワードでログインすると、`EnsureTwoFactorEnabled` ミドルウェアにより `/2fa/setup` へ自動誘導され、TOTP 登録とリカバリコード発行を行う。

## 構成上の位置づけ

```
curl で bootstrap.sh を取得 → 実行
  → private な bat-app fork を clone（既定 /opt/bat-app）
  → /opt/bat-app/infra/ansible で ansible-playbook（OS設定・SSH/TOTP・Docker）
  → docker compose up（BunkerWeb + アプリ一式）
  → 別端末で work+TOTP ログイン確認 → root SSH 無効化
```

- **bootstrap.sh**：本リポジトリ（公開・curl 配布）。`INFRA_DIR="${APP_DIR}/infra"` のとおり、置き場所に依存せず clone 先の Ansible を参照する。
- **Ansible 一式**：`bat-app` の `infra/ansible/`（private・fork される）。

## 関連リポジトリ

| リポジトリ | 役割 |
|---|---|
| **bat-bootstrap**（本リポ） | 入口スクリプト `bootstrap.sh` の公開配布 |
| bat-app | アプリ本体＋ Ansible（`infra/`）。fork して private 運用 |
| bat-doc | 設計資料（**BAT_サーバー構築手順書.docx** はここ） |
| bat-mock | HTML モック |

## 開発（このスクリプトを編集する場合）

`bootstrap.sh` の編集後は、`bash -n bootstrap.sh` で構文確認のうえコミットする。
対話フロー・SSH/TOTP・BunkerWeb の仕様は手順書（bat-doc）が正本なので、変更時は手順書との整合を保つこと。
