#!/usr/bin/env bash
# ============================================================
# bootstrap.sh — BAT 対話型サーバー構築スクリプト（ステップ1: 対話 + Ansible 呼び出し）
# 対象 OS: Rocky Linux 10.1 / 対象: Xserver VPS（固定グローバル IPv4）
#
# 役割（手順書 §1.3 段階[1]）:
#   1. 必須ツール（git, ansible-core）の導入
#   2. private リポ（bat-app の fork）の clone（Deploy key / PAT）
#   3. 対話で収集したパラメータを Ansible へ渡す vars / .env へ書き出し
#   4. ansible-playbook を local connection で実行し OS を本番設定
#   5. ★安全装置: work + TOTP ログイン成功を別端末で確認するまで停止し、
#      確認後に root SSH を無効化する（ロックアウト防止・手順書 §7.3）
#
# 取得・実行方法（手順書 §5.1）:
#   curl -fsSL https://raw.githubusercontent.com/<owner>/bat-bootstrap/main/bootstrap.sh -o bootstrap.sh
#   sudo bash bootstrap.sh
#   ※ curl | bash で直接パイプしてはならない（read による対話入力が壊れるため）。
#   ※ 本スクリプトは対話入力をすべて /dev/tty から読むため、万一パイプ実行されても動作する。
#
# 冪等性（手順書 §11.1）:
#   再実行しても安全。clone 済み→git pull、導入済みツール→スキップ、Ansible は冪等。
# ============================================================

set -euo pipefail

# ------------------------------------------------------------
# 表示ヘルパ（色付きログ）
# ------------------------------------------------------------
readonly C_RESET=$'\033[0m'
readonly C_INFO=$'\033[1;34m'   # 青: 情報
readonly C_OK=$'\033[1;32m'     # 緑: 成功
readonly C_WARN=$'\033[1;33m'   # 黄: 警告
readonly C_ERR=$'\033[1;31m'    # 赤: エラー

log()   { printf '%s[INFO]%s %s\n'  "$C_INFO" "$C_RESET" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n'  "$C_OK"   "$C_RESET" "$*"; }
warn()  { printf '%s[WARN]%s %s\n'  "$C_WARN" "$C_RESET" "$*"; }
err()   { printf '%s[FAIL]%s %s\n'  "$C_ERR"  "$C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }

# ------------------------------------------------------------
# 対話入力ヘルパ（手順書 §5 注記: read は必ず /dev/tty から読む）
#   ask        … 既定値つき通常入力（空入力で既定採用）
#   ask_secret … 非エコー入力（パスワード/トークン用。標準出力に残さない）
#   ask_yes_no … [y/N] 既定 No の確認
# ------------------------------------------------------------
ask() {
  # $1=プロンプト文 $2=既定値 → 標準出力に確定値を返す
  local prompt="$1" default="${2:-}" reply=""
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$prompt" "$default" > /dev/tty
  else
    printf '%s: ' "$prompt" > /dev/tty
  fi
  IFS= read -r reply < /dev/tty || true
  # 末尾 CR (Windows 改行 / 一部 SSH クライアントでの混入) を除去。
  # CR が残ると URL 末尾に \r が紛れ、to_ssh_url で「空リポ名」エラーを引き起こす。
  reply="${reply%$'\r'}"
  # 前後の空白 (タブ・空白) を除去。URL ペースト時の余白を吸収。
  reply="${reply#"${reply%%[![:space:]]*}"}"
  reply="${reply%"${reply##*[![:space:]]}"}"
  printf '%s' "${reply:-$default}"
}

ask_secret() {
  # $1=プロンプト文 → 非エコーで読み、標準出力に確定値を返す（履歴・画面に残さない）
  local prompt="$1" reply=""
  printf '%s: ' "$prompt" > /dev/tty
  IFS= read -rs reply < /dev/tty || true
  printf '\n' > /dev/tty
  # 末尾 CR と前後空白を除去（ask と同じ理由・トークンの末尾汚染防止）。
  reply="${reply%$'\r'}"
  reply="${reply#"${reply%%[![:space:]]*}"}"
  reply="${reply%"${reply##*[![:space:]]}"}"
  printf '%s' "$reply"
}

ask_yes_no() {
  # $1=プロンプト文 → y で 0、それ以外（既定）で 1 を返す
  local prompt="$1" reply=""
  printf '%s [y/N]: ' "$prompt" > /dev/tty
  IFS= read -r reply < /dev/tty || true
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ------------------------------------------------------------
# 0. 事前チェック（root 実行前提・手順書 §5.1 sudo bash）
# ------------------------------------------------------------
[[ "$(id -u)" -eq 0 ]] || die "root で実行してください（例: sudo bash bootstrap.sh）。"

# OS 確認（Rocky Linux 10 想定。異なる場合は警告のみで続行可）
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "rocky" ]]; then
    warn "想定 OS は Rocky Linux ですが、検出された OS は '${ID:-unknown} ${VERSION_ID:-}' です。続行は可能ですが動作保証外です。"
  else
    log "検出 OS: ${PRETTY_NAME:-Rocky Linux}"
  fi
fi

cat > /dev/tty <<BANNER

============================================================
  BAT サーバー構築 bootstrap.sh
  対話に答えるだけで OS 設定〜コンテナ起動まで自動構築します。
  （詳細: BAT_サーバー構築手順書 §6 対話フロー）

${C_WARN}★本スクリプトは構築完了時に root SSH を自動的に無効化します（手順書 §7.3）。${C_RESET}
  ロックアウト防止のため、実行前に以下を別端末で必ず確認してください:
    1. work ユーザーで公開鍵 SSH ログインができること
    2. work ユーザーで 'google-authenticator' を実行し TOTP 登録済みであること
    3. work ユーザーで「鍵＋TOTP 6桁」の 2 要素ログインが成功すること
  ※ 初回構築時は work ユーザーがまだ存在しません。その場合は本スクリプト
     完走後、root が無効化される直前に work が自動作成されるため、
     構築完了後の最初のログインまでに上記 1〜3 を必ず済ませてください。
============================================================

BANNER

# ------------------------------------------------------------
# 1. 続行確認 [y/N]（手順書 §6 手順1）
# ------------------------------------------------------------
ask_yes_no "このサーバーに対して本番構築を開始してよろしいですか？（root SSH は完走時に自動で無効化されます）" \
  || die "中止しました。"

# ============================================================
# 2. 必須ツール導入（手順書 §6 手順2 / 付録A: ここでは前提ツールのみ）
#    git と ansible-core を dnf で導入。標準リポに無ければ EPEL を有効化。
#    冪等: 既に導入済みのものはスキップ。
# ============================================================
log "必須ツール（git, ansible-core）の導入を確認します。"

ensure_pkg() {
  # $1=コマンド名 $2=dnf パッケージ名
  local cmd="$1" pkg="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "${pkg} は導入済みです（スキップ）。"
    return 0
  fi
  log "${pkg} を dnf で導入します。"
  if dnf install -y "$pkg" >/dev/null 2>&1; then
    ok "${pkg} を導入しました。"
    return 0
  fi
  # 標準リポに無い場合は EPEL を有効化して再試行（手順書 §6 手順2）
  warn "${pkg} を標準リポジトリから導入できませんでした。EPEL を有効化して再試行します。"
  dnf install -y epel-release >/dev/null 2>&1 || true
  dnf install -y "$pkg" >/dev/null 2>&1 \
    || die "${pkg} の導入に失敗しました。手動で 'dnf install ${pkg}' を実行してください。"
  ok "${pkg} を EPEL 経由で導入しました。"
}

ensure_pkg git git
# Ansible 本体（ansible-playbook を提供するのは ansible-core）
if command -v ansible-playbook >/dev/null 2>&1; then
  ok "ansible-core は導入済みです（スキップ）。"
else
  ensure_pkg ansible-playbook ansible-core
fi

# ============================================================
# 3. private リポ URL（手順書 §6 手順3）
# ============================================================
REPO_URL="$(ask "bat-app の fork（private リポジトリ）の URL を入力してください")"
[[ -n "$REPO_URL" ]] || die "リポジトリ URL は必須です。"

# ============================================================
# 4. clone 認証方式の選択（手順書 §6 手順4 / §9）
#    1) Deploy key（推奨・write 許可運用）  2) Fine-grained PAT
# ============================================================
cat > /dev/tty <<'AUTHMENU'

clone の認証方式を選択してください（手順書 §9）:
  1) Deploy key（推奨・write 許可・リポジトリ単位・失効容易）
  2) Fine-grained PAT（1 ステップだがトークン管理が必要）
AUTHMENU
AUTH_METHOD="$(ask "番号を入力" "1")"

# Deploy key 用に生成する鍵のパス（deploy + 開発者 push 兼用・write 許可運用 / 2026-06-26 運用変更）。
#
# ★セキュリティ注意（write 許可運用のトレードオフ）:
#   - 本鍵を保持するサーバー / ユーザーが侵害された場合、攻撃者が main へ
#     直接 push できる攻撃面が生じる（read-only 運用には無かったリスク）。
#   - CD 経路の侵害シナリオを許容しない構成にする場合は、本鍵を read-only に
#     戻し、CD 用には別途 write 許可の deploy key（または fine-grained PAT）を
#     分離する設計に切り替えることを推奨。
#   - 本スクリプトの想定は「開発者と CI が同一の write 許可 deploy key を
#     共有する小規模運用」（2026-06-26 運用方針）。
readonly DEPLOY_KEY="/root/.ssh/bat_deploy_key"

# REPO_URL を SSH 形式（git@github.com:owner/repo.git）へ正規化
to_ssh_url() {
  local u="$1"
  # 二重防御: ask 側で除去済だが、念のため末尾 CR / スラッシュも除去する。
  u="${u%$'\r'}"
  u="${u%/}"
  case "$u" in
    git@*)
      # git@github.com:owner/repo or git@github.com:owner/repo.git → 末尾 .git を一旦剥がして付け直す
      local path_part="${u#git@github.com:}"
      path_part="${path_part%.git}"
      path_part="${path_part%/}"
      printf 'git@github.com:%s.git' "$path_part"
      ;;
    https://github.com/*)
      # https://github.com/owner/repo(.git)(/) → git@github.com:owner/repo.git
      local path="${u#https://github.com/}"
      path="${path%.git}"
      path="${path%/}"
      printf 'git@github.com:%s.git' "$path"
      ;;
    *) printf '%s' "$u" ;;
  esac
}

# REPO_URL を https://<PAT>@github.com/owner/repo.git へ変換
to_https_pat_url() {
  local u="$1" pat="$2" path=""
  u="${u%$'\r'}"
  u="${u%/}"
  case "$u" in
    https://github.com/*) path="${u#https://github.com/}" ;;
    git@github.com:*)     path="${u#git@github.com:}" ;;
    *) die "PAT 認証では https/ssh の GitHub URL を指定してください: ${u}" ;;
  esac
  path="${path%.git}"
  path="${path%/}"
  printf 'https://%s@github.com/%s.git' "$pat" "$path"
}

prepare_clone_auth() {
  # 認証方式に応じて clone 用の git 環境を整える。
  # - Deploy key: ssh-keygen で鍵生成 → 公開鍵を表示 → GitHub 登録待ち → GIT_SSH_COMMAND を設定
  # - PAT       : 非エコーで読み、認証付き URL を組み立てる（履歴・画面に残さない）
  case "$AUTH_METHOD" in
    1)
      mkdir -p /root/.ssh && chmod 700 /root/.ssh
      if [[ ! -f "$DEPLOY_KEY" ]]; then
        log "Deploy key 用の SSH 鍵を生成します（ed25519）。"
        ssh-keygen -t ed25519 -N "" -C "bat-deploy-key" -f "$DEPLOY_KEY" >/dev/null
        ok "Deploy key を生成しました: ${DEPLOY_KEY}"
      else
        ok "Deploy key は既に存在します（再利用）: ${DEPLOY_KEY}"
      fi

      cat > /dev/tty <<DKMSG

------------------------------------------------------------
以下の【公開鍵】を GitHub の対象リポジトリに登録してください。
  GitHub ▸ 対象リポジトリ ▸ Settings ▸ Deploy keys ▸ Add deploy key
  ★Allow write access にチェックを入れて登録してください（運用変更 2026-06-26・手順書 §9.1）
------------------------------------------------------------
DKMSG
      cat "${DEPLOY_KEY}.pub" > /dev/tty
      printf '\n' > /dev/tty
      # 登録完了を待つ（手順書 §9.1: 登録後に Enter で clone）
      printf 'Deploy key を登録したら Enter を押してください... ' > /dev/tty
      IFS= read -r _ < /dev/tty || true

      # github.com のホスト鍵を known_hosts へ追加（対話プロンプトを避ける）
      ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts 2>/dev/null || true
      chmod 600 /root/.ssh/known_hosts 2>/dev/null || true

      # /root/.ssh/config に github.com の IdentityFile を永続記録する。
      # GIT_SSH_COMMAND は本スクリプト実行中だけ有効な環境変数なので、bootstrap.sh
      # 終了後に運用者が改めて `git pull` する際に Permission denied になる事故が
      # 起きる。/root/.ssh/config に Host github.com の IdentityFile を書いておけば、
      # 以降は root で素の `git pull` が通る。
      # 冪等: 既に同マーカーのブロックがあれば置換、無ければ追記。
      if ! grep -q "^# BEGIN BAT root github.com config" /root/.ssh/config 2>/dev/null; then
        cat >> /root/.ssh/config <<SSHCONF
# BEGIN BAT root github.com config (managed by bootstrap.sh)
Host github.com
  IdentityFile ${DEPLOY_KEY}
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
# END BAT root github.com config (managed by bootstrap.sh)
SSHCONF
        chmod 600 /root/.ssh/config
        ok "/root/.ssh/config に github.com の IdentityFile を記録しました（後続の root git pull が通るようにするため）。"
      fi

      # この鍵を使う git 用 SSH コマンド。CLONE_URL は SSH 形式へ正規化する。
      export GIT_SSH_COMMAND="ssh -i ${DEPLOY_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
      CLONE_URL="$(to_ssh_url "$REPO_URL")"
      ;;
    2)
      # PAT を非エコーで読む。トークンはファイルにも標準出力にも残さない。
      local pat
      pat="$(ask_secret "Fine-grained PAT を入力してください（入力は表示されません）")"
      [[ -n "$pat" ]] || die "PAT が入力されませんでした。"
      # https://<PAT>@github.com/... を組み立てる（手順書 §9.2）。
      # CLONE_URL はローカル変数に閉じ込め、ログ・vars には書き出さない。
      CLONE_URL="$(to_https_pat_url "$REPO_URL" "$pat")"
      unset pat
      ;;
    *)
      die "不正な選択です: ${AUTH_METHOD}（1 または 2 を入力してください）。"
      ;;
  esac
}

prepare_clone_auth

# ============================================================
# 5. 配置先ディレクトリ（固定 /opt/bat-app）
#    所有者方針により対話入力を撤廃し固定値化（commit ...追従 / v1.8）。
# ============================================================
readonly APP_DIR="/opt/bat-app"

# ============================================================
# 6. git clone 実行（手順書 §6 手順6 / §11.1 冪等: 既存なら git pull）
# ============================================================
if [[ -d "${APP_DIR}/.git" ]]; then
  log "既存リポジトリを検出しました。git pull で更新します（冪等）: ${APP_DIR}"
  git -C "$APP_DIR" pull --ff-only \
    || warn "git pull に失敗しました（ローカル変更やブランチ差異の可能性）。既存コードのまま続行します。"
  ok "リポジトリを更新しました。"
else
  log "リポジトリを clone します: ${APP_DIR}"
  mkdir -p "$(dirname "$APP_DIR")"
  git clone "$CLONE_URL" "$APP_DIR" \
    || die "clone に失敗しました。URL・認証（Deploy key / PAT）の登録内容を確認してください。"
  ok "clone が完了しました。"
fi
# 認証付き URL（PAT 等）はここで破棄し、以降のログ・ファイルに残さない。
unset CLONE_URL

readonly INFRA_DIR="${APP_DIR}/infra"
[[ -d "${INFRA_DIR}/ansible" ]] \
  || die "infra/ansible が見つかりません: ${INFRA_DIR}/ansible（リポジトリ構成を確認してください）。"

# ============================================================
# 7. 環境の選択（手順書 §6 手順7 / 付録B）
#    #599 Phase B: 「local」オプションを廃止し「検証(別サーバー)」へ置換。
#    ローカル開発環境は bootstrap 対象外（docker compose up で手動起動）。
#    1) 本番（Let's Encrypt）  2) 検証/staging（別サーバー・Let's Encrypt）
# ============================================================
cat > /dev/tty <<'ENVMENU'

構築する環境を選択してください（手順書 §8.1 TLS モード / #599 Phase B）:
  1) 本番        … Let's Encrypt の正式証明書（USE_LETS_ENCRYPT=yes / HSTS 有効）
  2) 検証(別サーバー) … 専用サブドメイン + Let's Encrypt（HSTS 有効・bootstrap で別サーバーを構築）
  ※ ローカル開発環境は bootstrap 対象外。docker compose up -d で手動起動してください。
ENVMENU
ENV_CHOICE="$(ask "番号を入力" "1")"
case "$ENV_CHOICE" in
  1) DEPLOY_ENV="production" ;;
  2) DEPLOY_ENV="staging" ;;
  *) die "不正な選択です: ${ENV_CHOICE}（1 または 2 を入力してください）。" ;;
esac

# ============================================================
# 7a. 本番選択時: このサーバーに staging を同居させるか対話（#599 Phase B）
#     同居=STAGING_MODE=colocated / 別鯖=STAGING_MODE=separate
# ============================================================
STAGING_MODE=""
STAGING_HOST=""

if [[ "$DEPLOY_ENV" == "production" ]]; then
  cat > /dev/tty <<'STAGINGMENU'

このサーバーに検証環境(staging)を同居させますか？（手順書 §8.3 / #599 Phase B）:
  1) 同居（colocated） … 同一サーバー上でポート 18443 で staging を起動
  2) 別サーバー（separate） … 別途 staging サーバーを bootstrap で構築
STAGINGMENU
  STAGING_CHOICE="$(ask "番号を入力" "1")"
  case "$STAGING_CHOICE" in
    1)
      STAGING_MODE="colocated"
      log "検証-同居モードを選択しました。staging は同サーバー上のポート 18443 で起動します（自己署名）。"
      ;;
    2)
      STAGING_MODE="separate"
      STAGING_HOST="$(ask "staging サーバーのホスト名または IP")"
      [[ -n "$STAGING_HOST" ]] || die "STAGING_MODE=separate では STAGING_HOST は必須です。"
      log "別サーバーモードを選択しました（STAGING_HOST=${STAGING_HOST}）。"
      ;;
    *)
      die "不正な選択です: ${STAGING_CHOICE}（1 または 2 を入力してください）。" ;;
  esac
fi

# ============================================================
# 8. ドメイン（SERVER_NAME）（手順書 §6 手順8 / 付録B）
# ============================================================
if [[ "$DEPLOY_ENV" == "production" ]]; then
  SERVER_NAME="$(ask "公開ドメイン（SERVER_NAME）" "bat.next-code.jp")"
elif [[ "$DEPLOY_ENV" == "staging" ]]; then
  SERVER_NAME="$(ask "検証用サブドメイン（例: staging.bat.next-code.jp）")"
  [[ -n "$SERVER_NAME" ]] || die "検証(別サーバー)では SERVER_NAME（専用サブドメイン）は必須です。"
fi
[[ -n "$SERVER_NAME" ]] || die "SERVER_NAME は必須です。"

# ============================================================
# 9. Let's Encrypt メール / DB パスワード（手順書 §6 手順9 / 付録B）
#    本番・検証(別サーバー)はいずれも LE が必要。
#    DB パスワードは空欄なら openssl で自動生成（標準出力には出さない）。
# ============================================================
LE_EMAIL=""
if [[ "$DEPLOY_ENV" == "production" || "$DEPLOY_ENV" == "staging" ]]; then
  LE_EMAIL="$(ask "Let's Encrypt 用メールアドレス（証明書通知先）" "admin@next-code.jp")"
  [[ -n "$LE_EMAIL" ]] || die "本番・検証(別サーバー)では Let's Encrypt 用メールが必須です。"
fi

# DB パスワード（本番・ローカル共通で必要。空欄なら自動生成）
gen_password() {
  # 英数字 32 文字の強パスワードを生成（記号は .env 取り回しの安全のため除外）
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32
  else
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
  fi
}
DB_PASSWORD="$(ask_secret "DB パスワード（空欄で自動生成）")"
if [[ -z "$DB_PASSWORD" ]]; then
  DB_PASSWORD="$(gen_password)"
  ok "DB パスワードを自動生成しました（値は画面に表示しません。生成 .env に保存されます）。"
fi
# DB root パスワードも併せて自動生成（compose の MYSQL_ROOT_PASSWORD 用）
DB_ROOT_PASSWORD="$(gen_password)"

# ============================================================
# 10. SSH: work 公開鍵（手順書 §6 手順10 / §7.1 / 付録B）
#     work ユーザー名は固定 `work`（所有者方針 / v1.8）。
#     公開鍵は複数行（END で終了）または 1 行貼り付けに対応。
# ============================================================
readonly WORK_USER="work"

cat > /dev/tty <<'PUBKEYMSG'

work ユーザーの authorized_keys に登録する【公開鍵】を貼り付けてください（手順書 §7.1）。
  - 1 行（ssh-ed25519 ... のような行）をそのまま貼り付け、Enter。
  - 複数行・複数鍵を登録する場合は行を貼り付け、最後に END だけの行を入力。
PUBKEYMSG
SSH_PUBKEYS=""
first_line=""
IFS= read -r first_line < /dev/tty || true
if [[ "$first_line" == "END" ]]; then
  die "公開鍵が入力されませんでした。work ユーザーへのログインに必須です。"
fi
SSH_PUBKEYS="$first_line"
# 追加行があれば END まで読み続ける（複数鍵対応）
while IFS= read -r line < /dev/tty; do
  [[ "$line" == "END" ]] && break
  [[ -z "$line" ]] && break   # 1 行だけ貼って空 Enter された場合はそこで確定
  SSH_PUBKEYS+=$'\n'"$line"
done
[[ "$SSH_PUBKEYS" == ssh-* || "$SSH_PUBKEYS" == ecdsa-* || "$SSH_PUBKEYS" == sk-* ]] \
  || warn "貼り付けられた公開鍵が ssh-/ecdsa-/sk- で始まっていません。形式を確認してください。"

# ============================================================
# 10b. deploy-bot 用 SSH 鍵自動生成（CD 専用ユーザー / v1.8）
#
#   deploy-bot は GitHub Actions（deploy-production.yml）から SSH で本番に
#   入って `make deploy-current` を実行する CD 専用ユーザー。
#   本スクリプトが ed25519 鍵を /root/.ssh/bat_cd_key に自動生成し、
#   公開鍵を bootstrap_vars.yml に書き出して ansible roles/users が
#   deploy-bot の authorized_keys に登録する。
#   秘密鍵は完走後にコンソール表示して、運用者が GitHub Secrets
#   PROD_SSH_KEY に登録できるようにする。
#
#   冪等性: 既に /root/.ssh/bat_cd_key が存在すれば再生成しない。
# ============================================================
readonly DEPLOY_BOT_KEY="/root/.ssh/bat_cd_key"

if [[ ! -f "$DEPLOY_BOT_KEY" ]]; then
  log "deploy-bot 用 SSH 鍵ペアを生成します（ed25519・無パスフレーズ）。"
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  ssh-keygen -t ed25519 -N "" -C "bat-cd-deploy-bot" -f "$DEPLOY_BOT_KEY" >/dev/null
  chmod 600 "$DEPLOY_BOT_KEY"
  chmod 644 "${DEPLOY_BOT_KEY}.pub"
  ok "deploy-bot 用 SSH 鍵を生成しました: $DEPLOY_BOT_KEY"
else
  log "deploy-bot 用 SSH 鍵は既に存在します: $DEPLOY_BOT_KEY（再生成しません）"
fi

DEPLOY_BOT_PUBKEY="$(cat "${DEPLOY_BOT_KEY}.pub")"

# ============================================================
# 11. バックアップ設定（#665 backup role 向け）
#     GCS バケット名と保持日数を対話で収集する。
#     ★ GCS SA キー JSON 本体はここでは取り扱わない（鍵漏洩リスク軽減）。
#     構築後に手動で /etc/bat/gcs-sa-key.json へ配置すること（roles/backup/README.md §3 参照）。
# ============================================================
cat > /dev/tty <<'BKUPMSG'

---- バックアップ設定（#665 backup role） ----
GCS バケットへの binlog 転送設定を行います。
★ GCS SA キー JSON は構築後に手動で /etc/bat/gcs-sa-key.json へ配置してください。
  （キー漏洩リスクのため bootstrap.sh では取り扱いません: roles/backup/README.md §3）
BKUPMSG
GCS_BUCKET="$(ask "バックアップ先 GCS バケット名（例: bat-backup-binlog）" "")"
if [[ -z "$GCS_BUCKET" ]]; then
  warn "GCS バケット名が未設定です。bat:backup:binlog-ship は BAT_BINLOG_GCS_BUCKET 未設定でスキップされます。"
  warn "後から .env.production に BAT_BINLOG_GCS_BUCKET を追記してください（docs/runbook-backup-restore.md §2）。"
fi
BACKUP_RETENTION_DAYS="$(ask "バックアップ保持日数" "8")"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-8}"

# ============================================================
# 収集値の書き出し（機密は infra 配下の生成 config に限定し、権限 600）
#   - vars ファイル: Ansible へ非機密パラメータを渡す（YAML）
#   - secrets env  : 機密（DB パスワード等）を 600 で保存。app_deploy role が .env 生成に使用。
#   ※ 機密は標準出力に出さない / bootstrap.sh にハードコードしない（手順書 §6 末尾の方針）。
# ============================================================
GEN_DIR="${INFRA_DIR}/.generated"
mkdir -p "$GEN_DIR"
chmod 700 "$GEN_DIR"

VARS_FILE="${GEN_DIR}/bootstrap_vars.yml"
SECRETS_FILE="${GEN_DIR}/secrets.env"

# --- cert モード判定（#599 Phase B）---
# 本番=LE / 検証-別鯖=LE / 検証-同居=自己署名 / ローカル=自己署名（bootstrap 対象外）
_use_letsencrypt="no"
_generate_self_signed="no"
_use_hsts="no"
case "$DEPLOY_ENV" in
  production)
    _use_letsencrypt="yes"
    _use_hsts="yes"
    ;;
  staging)
    # 別サーバー検証: LE + HSTS 有効
    _use_letsencrypt="yes"
    _use_hsts="yes"
    ;;
esac
# 同居検証の自己署名は staging compose（docker-compose.staging.yml）が GENERATE_SELF_SIGNED_SSL=yes で制御するため、
# 本 vars には generate_self_signed=no（本番 compose は LE が前提）を書き出す。
if [[ "$STAGING_MODE" == "colocated" ]]; then
  # 同居 staging 専用フラグ（app_deploy role が staging compose を追加起動するため記録）
  _staging_mode="colocated"
else
  _staging_mode="${STAGING_MODE:-none}"
fi

# --- 非機密 vars（YAML）。Ansible に --extra-vars で渡す ---
umask 077
cat > "$VARS_FILE" <<VARS
---
# bootstrap.sh が対話入力から生成（手順書 付録B 対話入力→設定マッピング）。
# 機密値は含めない（機密は secrets.env 参照）。
deploy_env: "${DEPLOY_ENV}"
server_name: "${SERVER_NAME}"
le_email: "${LE_EMAIL}"
work_user: "${WORK_USER}"
app_dir: "${APP_DIR}"
infra_dir: "${INFRA_DIR}"
# work ユーザーへ登録する公開鍵（authorized_keys, perm 600）
work_ssh_authorized_keys: |
$(printf '%s\n' "$SSH_PUBKEYS" | sed 's/^/  /')
# deploy-bot 用（CD 専用ユーザー・GitHub Actions から SSH で入る / v1.8）
deploy_bot_user: "deploy-bot"
deploy_bot_ssh_authorized_keys: "${DEPLOY_BOT_PUBKEY}"
# TLS モード（手順書 §8.1 / #599 Phase B cert モード判定）。app_deploy role が compose env へ反映。
use_letsencrypt: "${_use_letsencrypt}"
generate_self_signed: "${_generate_self_signed}"
use_hsts: "${_use_hsts}"
# 検証環境モード（#599 Phase B §8）
# colocated=本番同居（app_deploy role が staging compose も追加起動）
# separate=別サーバー構築（staging サーバー上で bootstrap を実行）
# none=staging 構築なし
staging_mode: "${_staging_mode}"
staging_host: "${STAGING_HOST}"
# 機密 env ファイルの場所（app_deploy role が読み込んで .env を生成）
secrets_env_path: "${SECRETS_FILE}"
# バックアップ設定（#665 backup role）
gcs_bucket: "${GCS_BUCKET}"
backup_retention_days: ${BACKUP_RETENTION_DAYS}
VARS

# --- 機密 env（KEY=VALUE）。app_deploy role が .env 生成に使用 ---
cat > "$SECRETS_FILE" <<SECRETS
# bootstrap.sh が生成した機密値（権限 600・git 管理外）。
# app_deploy role がこれを基に ${APP_DIR}/.env を生成する想定（手順書 付録A app_deploy）。
DB_PASSWORD=${DB_PASSWORD}
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
SECRETS
chmod 600 "$VARS_FILE" "$SECRETS_FILE"
# 機密値はメモリ上からも破棄
unset DB_PASSWORD DB_ROOT_PASSWORD
ok "対話値を書き出しました（機密は 600 で保護）:"
log "  vars   : ${VARS_FILE}"
log "  secrets: ${SECRETS_FILE}（DB パスワード等。画面には表示しません）"

# ============================================================
# Ansible 実行（手順書 §6 手順9〜 / 付録A の role 群を local connection で適用）
#   site.yml の roles 順: common, swap, users, ssh_hardening, totp,
#                         firewalld, fail2ban, docker, app_deploy
#   ★この時点では ssh_hardening は root 無効化を行わない設計（後述の確認待ち後に適用）。
# ============================================================
# Ansible collections を導入（requirements.yml: ansible.posix の firewalld・community.docker 等）
if [[ -f "${INFRA_DIR}/ansible/requirements.yml" ]]; then
  log "Ansible collections を導入します（requirements.yml）。"
  ansible-galaxy collection install -r "${INFRA_DIR}/ansible/requirements.yml"
fi

log "Ansible playbook を local connection で実行します（OS 設定〜コンテナ起動）。"
ansible-playbook \
  -i "${INFRA_DIR}/ansible/inventory/localhost.yml" \
  "${INFRA_DIR}/ansible/site.yml" \
  -c local \
  --extra-vars "@${VARS_FILE}" \
  --extra-vars "disable_root_ssh=false"
ok "Ansible によるサーバー設定が完了しました。"

# ============================================================
# root SSH 無効化（手順書 §6 手順10 / §7.3）
#
#   起動時の冒頭バナーで「完走時に root SSH を自動無効化する」旨を予告し、
#   続行確認（ask_yes_no）の Yes をもってロックアウトの了承とみなす設計。
#   ここでは確認対話を挟まず、ssh_hardening role を disable_root_ssh=true で
#   再適用して PermitRootLogin no を反映する（冪等）。
#
#   【設計メモ】2-pass フロー（1回目 disable=false / 2回目 disable=true）は
#   ssh_hardening role 内の when ガードに依存しており、role 自体は冪等のため
#   再適用しても sshd reload 以外の副作用はない。
#   work + TOTP の事前準備が未完で本処理が走った場合、root 無効化後に
#   work でログインできない事故が起きうるため、冒頭バナーの 1〜3 を必ず
#   完了させてから bootstrap.sh を実行すること。
# ============================================================
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
cat > /dev/tty <<NOTICE

============================================================
${C_WARN}★ root SSH を自動的に無効化します（手順書 §7.3）${C_RESET}

work ユーザー（${WORK_USER}）+ TOTP の 2 要素ログインが
別端末で成功する状態であることを前提に処理を進めます。

  別端末での確認コマンド:
    ssh ${WORK_USER}@${SERVER_IP:-<このサーバーの固定IP>}
    → 「秘密鍵（公開鍵認証）＋ TOTP 6 桁コード」でログインできること

  ※ 構築直後で TOTP 未登録の場合は、root が無効化される前に
     work で 'google-authenticator' を実行して QR を登録してください
     （手順書 §7.2.2）。
============================================================
NOTICE

log "root SSH を無効化します（ssh_hardening role を disable_root_ssh=true で再適用）。"
ansible-playbook \
  -i "${INFRA_DIR}/ansible/inventory/localhost.yml" \
  "${INFRA_DIR}/ansible/site.yml" \
  -c local \
  --extra-vars "@${VARS_FILE}" \
  --extra-vars "disable_root_ssh=true" \
  --tags ssh_hardening
ok "root SSH ログインを無効化しました（PermitRootLogin no）。"

# ============================================================
# 機密ファイル cleanup（任意・推奨）
#   secrets.env は DB_PASSWORD / DB_ROOT_PASSWORD を平文で保持する 600 ファイル。
#   構築完了後はもう不要のため、ここで対話で削除可否を確認する。
#   削除しても vars.yml は残るため再実行可能性は保たれる（再対話入力で再生成）。
# ============================================================
cat > /dev/tty <<CLEANUP

============================================================
${C_WARN}機密ファイルのクリーンアップ（推奨）${C_RESET}

以下のファイルに DB パスワード等の機密が平文で残置しています:
  ${SECRETS_FILE}

これらは構築完了後は不要のため削除を推奨します。
削除後も .env.production には機密値が反映済みのため再起動・運用には影響しません。
ただし、Ansible を同条件で再実行したい場合は手動で再生成が必要になります。
============================================================
CLEANUP

if ask_yes_no "${SECRETS_FILE} を削除しますか？（推奨: y）"; then
  if rm -f "${SECRETS_FILE}"; then
    ok "${SECRETS_FILE} を削除しました。"
  else
    warn "${SECRETS_FILE} の削除に失敗しました。手動で削除してください: rm -f ${SECRETS_FILE}"
  fi
else
  warn "機密ファイルを残置しました。VPS のセキュリティに留意してください: ${SECRETS_FILE}"
fi

# ============================================================
# 完走通知: deploy-bot 秘密鍵を GitHub Secrets PROD_SSH_KEY に登録（v1.8）
#   GitHub Actions (deploy-production.yml) が deploy-bot として SSH ログインし、
#   make deploy-current を実行する。秘密鍵は本サーバー上 (/root/.ssh/bat_cd_key)
#   にも残置されるが、CD 経路は GitHub Secrets 経由が正本。
# ============================================================
SERVER_PRIMARY_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
cat > /dev/tty <<DEPLOYKEYMSG

============================================================
${C_WARN}★ GitHub Secrets PROD_SSH_KEY 登録用の秘密鍵${C_RESET}

以下の秘密鍵を GitHub の Secrets に登録してください
（GitHub Actions deploy-production.yml が deploy-bot として
 本番にログインするのに使用します）:

  登録 URL : https://github.com/nextcode-bat/bat-app/settings/secrets/actions
  Secret 名: PROD_SSH_KEY
  値       : 下の -----BEGIN OPENSSH PRIVATE KEY----- から
             -----END OPENSSH PRIVATE KEY----- までの全行を貼り付け

----- 秘密鍵（コピー用）-----
$(cat "$DEPLOY_BOT_KEY")
----- 秘密鍵ここまで -----

PROD_HOST と PROD_USER も合わせて登録してください:
  PROD_HOST: ${SERVER_PRIMARY_IP:-<このサーバーの固定IP>}
  PROD_USER: deploy-bot

秘密鍵ファイルはサーバー上に ${DEPLOY_BOT_KEY} として保存されています
（権限 0600・root 読み取り専用）。
============================================================
DEPLOYKEYMSG

cat > /dev/tty <<'DONE'

============================================================
  構築フロー完了。次の確認を行ってください（手順書 §10）:
   1) https://<SERVER_NAME>/ へアクセスし証明書と WAF 応答を確認
   2) /healthz が HTTP 200 を返すこと
   3) ssh work@<IP> が 2 要素で成功し、root SSH は拒否されること
   4) GitHub Secrets に PROD_SSH_KEY / PROD_HOST / PROD_USER を登録
      （deploy-production.yml が deploy-bot として SSH ログインする）
============================================================
DONE
ok "bootstrap.sh を終了します。"
