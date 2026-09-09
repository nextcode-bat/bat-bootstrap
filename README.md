# bat-bootstrap

BAT サーバー自動構築の **入口スクリプト `bootstrap.sh` を公開配布するためのリポジトリ**。

本番サーバー（Xserver VPS 等）に root で SSH 到達した状態から、対話形式で
OS 設定・SSH 公開鍵認証（TOTP は任意登録）・Docker・BunkerWeb(WAF) までを自動構築する。

- 本リポジトリは **公開**。機密情報は一切含まない。
- アプリ本体（`bat-app` の fork）は **private** のままとし、`bootstrap.sh` が対話で受け取った認証情報（Deploy key / PAT）で clone する。
- 詳細手順は設計資料 **BAT_サーバー構築手順書.docx**（`../bat-doc/docs/基本設計/`）を参照。

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

> **任意（推奨）: 取得内容の固定と改ざん検証**
> main の最新ではなくタグ（またはコミット SHA）で固定した URL から取得し、
> 別経路で計算した sha256 と照合すると、配布経路の改ざん・取り違えを検出できる。
>
> ```bash
> curl -fsSL https://raw.githubusercontent.com/nextcode-bat/bat-bootstrap/<タグまたはコミットSHA>/bootstrap.sh -o bootstrap.sh
> sha256sum bootstrap.sh
> # 別経路（手元の git clone 等）で計算した同一版の sha256 と一致することを確認してから実行する
> ```

対話で順に質問される（続行確認／リポURL／clone認証／ドメイン／メール・DBパス／公開鍵）。
本番専用で、配置先は `/opt/bat-app`、SSH ユーザーは `work` に固定される。
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
cd /opt/bat-app
sudo docker compose --env-file .env.production -f docker-compose.production.yml exec app php artisan bat:create-user
```

作成直後は 2FA 未設定（`totp_enabled_at = null`）。
ブラウザで `https://<SERVER_NAME>/login` にユーザー名・パスワードでログインすると、`EnsureTwoFactorEnabled` ミドルウェアにより `/2fa/setup` へ自動誘導され、TOTP 登録とリカバリコード発行を行う。

## SSH の認証

`work` への SSH ログインは公開鍵を必須とし、パスワード認証は禁止する。
PAM の `pam_google_authenticator.so nullok` により、`google-authenticator` を設定しなければ公開鍵だけでログインできる。
TOTP を使う場合は、`work` で `google-authenticator` を実行して認証アプリへ登録する。
登録後は公開鍵と TOTP コードの両方が必要になる。

構築完了時に root SSH は自動で無効になるため、`ssh work@<VPS_IP>` が成功するまで現在の root セッションを閉じないこと。
旧バージョンの TOTP 完全必須化（`totp_enforce`）は廃止し、再適用でも `nullok` を維持する。
Web アプリの 2FA 設定は SSH の TOTP 登録とは別に行う。

## GitHub Actions の接続設定

`deploy-production` は main への push と Actions からの手動起動に対応する。
bootstrap が表示する接続用情報を、対象リポジトリの production environment の `PROD_HOST` / `PROD_USER` / `PROD_SSH_KEY` に登録する。
手動ロールバックを利用する場合は、production-rollback environment にも接続用 Secrets と `PROD_HOST_FINGERPRINT` を設定し、Required reviewers を構成する。

## 構成上の位置づけ

```
curl で bootstrap.sh を取得 → 実行
  → private な bat-app fork を clone（既定 /opt/bat-app）
  → /opt/bat-app/infra/ansible で ansible-playbook（OS設定・SSH/TOTP・Docker）
  → docker compose up（BunkerWeb + アプリ一式）
  → 全 role の適用成功後に root SSH 無効化（自動）
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

`bootstrap.sh` の編集後は、`bash -n bootstrap.sh` と `shellcheck bootstrap.sh`、`python3 -m unittest discover -s tests -v` を実行する。
対話フロー・SSH/TOTP・BunkerWeb の仕様は手順書（bat-doc）が正本なので、変更時は手順書との整合を保つこと。
