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
#   5. ★root SSH の無効化は完走時に自動実行される（手順書 §7.3）。
#      冒頭の続行確認 [y/N] 後、2 パスで構築する:
#        [1] 全 role 適用（root SSH は維持）
#        [2] ssh_hardening 再適用で root SSH 無効化（確認対話なし・自動）
#      TOTP は任意登録。未登録なら公開鍵のみ、登録済みなら公開鍵 + TOTP。
#
# 取得・実行方法（手順書 §5.1）:
#   curl -fsSL https://raw.githubusercontent.com/<owner>/bat-bootstrap/main/bootstrap.sh -o bootstrap.sh
#   sudo bash bootstrap.sh
#   ※ curl | bash で直接パイプしてはならない（read による対話入力が壊れるため）。
#   ※ 本スクリプトは対話入力をすべて /dev/tty から読むため、万一パイプ実行されても動作する。
#
# 冪等性（手順書 §12.1）:
#   再実行しても安全。clone 済み→git pull、導入済みツール・生成済み鍵→スキップ、
#   Ansible は冪等。DB/Redis パスワード等の機密は .env.production が既存なら
#   再生成せず既存値を維持する（MySQL 実体と .env の食い違いによる接続不能を防止）。
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

# 対話入力の軽量形式検証。打ち間違い・危険文字（引用符等）の混入を
# vars/YAML へ書き出す前に検出して die する。
validate_hostname() {
  # $1=項目名 $2=値（英数字・ドット・ハイフンのみ許可）
  [[ "$2" =~ ^[A-Za-z0-9.-]+$ ]] \
    || die "${1} に使用できない文字が含まれています: '${2}'（英数字・ドット・ハイフンのみ使用可能）。"
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
  手元の SSH 秘密鍵に対応する公開鍵を、この後 work ユーザーへ登録します。
  初回は work が自動作成され、公開鍵だけで SSH ログインできます。
  TOTP は任意です。work で google-authenticator を実行した場合は、
  以後の SSH ログインで公開鍵に加えて TOTP コードが必要です。
  作業中の root セッションは、work でログインできるまで閉じないでください。
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

# ------------------------------------------------------------
# GitHub SSH ホスト鍵の固定検証（#1109 / セキュリティ要件 SSH 接続）
#
# 旧実装は StrictHostKeyChecking=accept-new による TOFU（初回接続時に
# 表示された鍵を信用する方式）だったが、初回接続が MITM 経路だった場合に
# 偽の鍵を known_hosts に焼き付けてしまうリスクが残る。
#
# 本ブロックは GitHub 公式が公開している SHA256 指紋値をスクリプト内に
# 埋め込み、ssh-keyscan の結果と一致比較してから既知ホストとして固定する
# 「鍵ピンニング方式」へ切り替える。一致しなければスクリプトを即時 abort
# し、運用者へ MITM の可能性を通知する。
#
# 出典: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
# 値の取得日: 2026-07-01（再検証は ssh-keygen -lf でローカル一致確認済み）
# 鍵ローテーション時は本定数を更新し、サーバー構築手順書のセキュリティ
# 節も追従改訂すること（CLAUDE.md「BAT_セキュリティ要件」参照）。
# ------------------------------------------------------------
readonly GITHUB_HOST_FP_ED25519="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"
readonly GITHUB_HOST_FP_ECDSA="SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM"
readonly GITHUB_HOST_FP_RSA="SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s"

# verify_and_pin_github_host_key
#   ssh-keyscan で github.com のホスト鍵を取得し、上記公式指紋と一致する
#   ことを検証してから known_hosts に固定追記する（accept-new を撤廃）。
#
#   引数:
#     $1 = 追記先 known_hosts のパス
#          （既定: /etc/ssh/ssh_known_hosts。システムワイドに置くことで
#           bootstrap.sh 完走後に Ansible が作成する work ユーザーも追加
#           設定なく同じ既知鍵を継承する。所有者方針: root:root / 0644）
#
#   冪等性:
#     既に対象ファイルに ^github.com の行があれば skip し、再書き込みしない。
#
#   失敗時の挙動:
#     - ssh-keyscan が 3 回連続で失敗 → die（ネットワーク不通の可能性）
#     - 取得した鍵の SHA256 指紋が埋め込み値と不一致 → die（MITM 検知）
verify_and_pin_github_host_key() {
  local target="${1:-/etc/ssh/ssh_known_hosts}"
  local target_dir
  target_dir="$(dirname "$target")"

  mkdir -p "$target_dir"

  # 既に github.com が登録済みなら skip（冪等性・手順書 §12.1）。
  # ただし skip する前に既存行の SHA256 指紋を公式値と照合し、不一致
  # （過去の TOFU 期に焼き付いた偽鍵の可能性）を検出したら警告と復旧手順を出す。
  if [[ -f "$target" ]] && grep -q '^github\.com ' "$target" 2>/dev/null; then
    local existing_line existing_fp mismatch=0
    while IFS= read -r existing_line; do
      existing_fp="$(printf '%s\n' "$existing_line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' || true)"
      case "$existing_fp" in
        "$GITHUB_HOST_FP_ED25519"|"$GITHUB_HOST_FP_ECDSA"|"$GITHUB_HOST_FP_RSA")
          ;;
        *)
          mismatch=$((mismatch + 1))
          warn "既存の github.com ホスト鍵が GitHub 公式指紋と不一致です: 指紋=${existing_fp:-解析不能}"
          ;;
      esac
    done < <(grep '^github\.com ' "$target")
    if (( mismatch > 0 )); then
      warn "MITM または鍵ローテーションの可能性があります。復旧手順:"
      warn "  1. ${target} から 'github.com ' で始まる行を削除する"
      warn "  2. bootstrap.sh を再実行する（公式指紋と照合のうえ再固定されます）"
      die "既存の github.com ホスト鍵を検証できないため中止しました。"
    else
      ok "github.com のホスト鍵は既に ${target} に固定済み（指紋一致を確認・skip）。"
    fi
    return 0
  fi

  # ssh-keyscan を最大 3 回リトライ（ネットワーク一時不通対策）
  local scanned="" attempt=0
  while (( attempt < 3 )); do
    attempt=$((attempt + 1))
    log "github.com のホスト鍵を取得します（ssh-keyscan / 試行 ${attempt}/3）。"
    if scanned="$(ssh-keyscan -T 10 -t ed25519,ecdsa,rsa github.com 2>/dev/null)" \
        && [[ -n "$scanned" ]]; then
      break
    fi
    warn "ssh-keyscan に失敗しました（試行 ${attempt}/3）。"
    scanned=""
    sleep 2
  done
  [[ -n "$scanned" ]] \
    || die "github.com のホスト鍵を取得できませんでした（DNS / ファイアウォール / 上流ネットワークを確認してください）。"

  # 取得した各行を SHA256 指紋に変換し、埋め込み値と一致するか検証。
  # known_hosts へは検証に合格した行だけを追記する（未知種別の鍵を無検証で
  # 固定しないため、合格行を verified_lines に集める）。
  local verified=0 verified_lines=""
  local line fp_line fp algo
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    fp_line="$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null || true)"
    [[ -z "$fp_line" ]] && continue
    # 形式例: "256 SHA256:xxxxx... github.com (ED25519)"
    fp="$(awk '{print $2}' <<< "$fp_line")"
    algo="$(awk '{print $NF}' <<< "$fp_line" | tr -d '()')"
    case "$algo" in
      ED25519)
        [[ "$fp" == "$GITHUB_HOST_FP_ED25519" ]] \
          || die "github.com ED25519 鍵指紋が GitHub 公式値と不一致（MITM の可能性）: 取得=${fp} / 期待=${GITHUB_HOST_FP_ED25519}"
        ok "github.com ED25519 指紋一致を確認: ${fp}"
        verified=$((verified + 1))
        verified_lines+="${line}"$'\n'
        ;;
      ECDSA)
        [[ "$fp" == "$GITHUB_HOST_FP_ECDSA" ]] \
          || die "github.com ECDSA 鍵指紋が GitHub 公式値と不一致（MITM の可能性）: 取得=${fp} / 期待=${GITHUB_HOST_FP_ECDSA}"
        ok "github.com ECDSA 指紋一致を確認: ${fp}"
        verified=$((verified + 1))
        verified_lines+="${line}"$'\n'
        ;;
      RSA)
        [[ "$fp" == "$GITHUB_HOST_FP_RSA" ]] \
          || die "github.com RSA 鍵指紋が GitHub 公式値と不一致（MITM の可能性）: 取得=${fp} / 期待=${GITHUB_HOST_FP_RSA}"
        ok "github.com RSA 指紋一致を確認: ${fp}"
        verified=$((verified + 1))
        verified_lines+="${line}"$'\n'
        ;;
      *)
        warn "未知の鍵種別を検出したため検証対象外（スキップ）: algo=${algo}"
        ;;
    esac
  done <<< "$scanned"

  # 1 件も検証成功しなかった場合は安全側に倒して abort（鍵欠落 / 解析失敗）
  (( verified > 0 )) \
    || die "github.com のホスト鍵検証が 0 件成功でした。ssh-keyscan / ssh-keygen の出力解析に失敗している可能性があります。"

  # 検証 OK: 指紋検証に合格した行だけを known_hosts に固定追記する
  # （追記方式: 既存の他ホストエントリを破壊しない）
  printf '%s' "$verified_lines" >> "$target"
  chmod 644 "$target"
  ok "github.com のホスト鍵 ${verified} 件を ${target} に固定しました（鍵ピンニング完了）。"
}

# REPO_URL を SSH 形式（git@github.com:owner/repo.git）へ正規化
to_ssh_url() {
  local https_url
  https_url="$(to_plain_https_url "$1")" || return 1
  printf 'git@github.com:%s' "${https_url#https://github.com/}"
}

# REPO_URL を素の https://github.com/owner/repo.git へ正規化（PAT 認証用）。
# PAT は URL へ埋め込まない（URL は git の引数列に載り、実行中は ps で全ユーザー
# から観測できるため）。認証は GIT_ASKPASS の一時スクリプトが応答する。
to_plain_https_url() {
  local u="$1" path=""
  u="${u%$'\r'}"
  u="${u%/}"
  case "$u" in
    https://github.com/*) path="${u#https://github.com/}" ;;
    git@github.com:*)     path="${u#git@github.com:}" ;;
    *) die "https/ssh の GitHub URL を指定してください。" ;;
  esac
  path="${path%.git}"
  path="${path%/}"
  [[ "$path" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ && "${path#*/}" != "." && "${path#*/}" != ".." ]] \
    || die "GitHub URL は owner/repository の形式で指定してください。"
  printf 'https://github.com/%s.git' "$path"
}

# remote.origin.url から資格情報（userinfo 部）を除去する（#1192）。
#   PAT 経路の clone は https://<PAT>@github.com/... を .git/config の
#   remote.origin.url に書き込むため、そのままでは PAT が .git/config
#   （0644・全ユーザー可読）に永続残置される。clone / pull 完了直後に
#   本関数で資格情報なしの素の https URL へ書き戻す。
#   Deploy key 経路の URL（git@github.com:...）は https://*@* に一致しない
#   ため no-op。過去の実行で埋め込まれた資格情報も本関数で掃除される。
scrub_origin_credentials() {
  local dir="$1" current="" cleaned=""
  current="$(git -C "$dir" remote get-url origin 2>/dev/null)" || return 0
  case "$current" in
    https://*@*)
      # userinfo（<PAT>@ / user:pass@）を最長一致（最終 @ まで）で除去した
      # URL に組み替える。userinfo 内に @ を含む異常系でも資格情報を確実に
      # 全除去する側へ倒す（GitHub の owner/repo 名に @ は使えないため、
      # ホスト名以降を誤って切り詰める実害はない・review-1192 軽微-1）。
      cleaned="https://${current##*@}"
      git -C "$dir" remote set-url origin "$cleaned" \
        || { warn "remote.origin.url の資格情報除去に失敗しました。手動で実行してください: git -C ${dir} remote set-url origin ${cleaned}"; return 0; }
      ok "remote.origin.url から資格情報を除去しました（PAT の .git/config 残置防止・#1192）: ${cleaned}"
      ;;
  esac
  return 0
}

prepare_clone_auth() {
  # 認証方式に応じて clone 用の git 環境を整える。
  # - Deploy key: ssh-keygen で鍵生成 → 公開鍵を表示 → GitHub 登録待ち → GIT_SSH_COMMAND を設定
  # - PAT       : 非エコーで読み、認証付き URL を組み立てる（履歴・画面に残さない）

  # github.com のホスト鍵を /etc/ssh/ssh_known_hosts へ「固定」する（#1109）。
  # 旧実装の accept-new による TOFU は撤廃し、GitHub 公式の SHA256 指紋との
  # プレ検証を経た上でシステムワイドに鍵をピンニングする。システムワイドに
  # 置くことで、bootstrap.sh 完走後に Ansible が作成する work ユーザーも追加
  # 設定なく同じ既知鍵を継承する（手順書 §9 / §7.1）。
  # #1192（review-1189 A-3）: 旧実装は本呼出が Deploy key 分岐内のみにあり、
  # PAT(https) 構築経路では known_hosts が未固定のまま完走していた。PAT 経路
  # でも完走後に work ユーザーが ssh fetch へ移行する可能性があるため、
  # 認証方式に依らず分岐前で共通実行する（検証ロジック自体は #1109 のまま）。
  verify_and_pin_github_host_key "/etc/ssh/ssh_known_hosts"

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

      # github.com のホスト鍵ピンは prepare_clone_auth 冒頭（分岐前）で
      # 共通実行済み（#1109 / #1192）。

      # /root/.ssh/config に github.com の IdentityFile を永続記録する。
      # GIT_SSH_COMMAND は本スクリプト実行中だけ有効な環境変数なので、bootstrap.sh
      # 終了後に運用者が改めて `git pull` する際に Permission denied になる事故が
      # 起きる。/root/.ssh/config に Host github.com の IdentityFile を書いておけば、
      # 以降は root で素の `git pull` が通る。
      # 冪等: 既存のマーカー間ブロックを削除してから【ファイル先頭】へ挿入する。
      # ssh_config は先勝ち（first-match-wins）のため、末尾追記だと既存の
      # Host github.com 設定に先取りされて本ブロックが効かないことがある。
      touch /root/.ssh/config
      _ssh_cfg_rest="$(mktemp)"
      sed '/^# BEGIN BAT root github.com config/,/^# END BAT root github.com config/d' \
        /root/.ssh/config > "$_ssh_cfg_rest"
      {
        cat <<SSHCONF
# BEGIN BAT root github.com config (managed by bootstrap.sh)
Host github.com
  IdentityFile ${DEPLOY_KEY}
  IdentitiesOnly yes
  # 事前に指紋検証のうえ /etc/ssh/ssh_known_hosts へ固定済みのエントリを厳格検証する
  StrictHostKeyChecking yes
# END BAT root github.com config (managed by bootstrap.sh)
SSHCONF
        cat "$_ssh_cfg_rest"
      } > /root/.ssh/config
      rm -f "$_ssh_cfg_rest"
      chmod 600 /root/.ssh/config
      ok "/root/.ssh/config の先頭に github.com の IdentityFile ブロックを記録しました（先勝ち規則のため先頭へ・後続の root git pull 用）。"

      # この鍵を使う git 用 SSH コマンド。CLONE_URL は SSH 形式へ正規化する。
      # #1109: accept-new(TOFU) を撤廃し、verify_and_pin_github_host_key で
      # 固定済みの /etc/ssh/ssh_known_hosts に対する厳格検証へ切り替え。
      export GIT_SSH_COMMAND="ssh -i ${DEPLOY_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes"
      CLONE_URL="$(to_ssh_url "$REPO_URL")"
      ;;
    2)
      # PAT を非エコーで読む。トークンは画面・ログ・git の引数列に残さない。
      local pat pat_escaped
      pat="$(ask_secret "Fine-grained PAT を入力してください（入力は表示されません）")"
      [[ -n "$pat" ]] || die "PAT が入力されませんでした。"
      # PAT は URL へ埋め込まず（argv は ps で全ユーザーから観測可能）、git の
      # 認証プロンプトに応答する一時スクリプト（root 専用 700）を GIT_ASKPASS に
      # 指定する（手順書 §9.2）。スクリプトは clone / pull 完了後に即削除し、
      # 異常終了時の取りこぼしは trap EXIT で防ぐ。
      GIT_ASKPASS_SCRIPT="$(mktemp /root/.bat_askpass.XXXXXX)"
      chmod 700 "$GIT_ASKPASS_SCRIPT"
      trap 'rm -f "${GIT_ASKPASS_SCRIPT:-}"' EXIT
      # PAT 内の単一引用符を '\'' へエスケープして埋め込む（GitHub PAT は英数字と
      # _ のみだが、異常入力でもスクリプトが壊れない側に倒す）。
      local _sq="'\\''"
      pat_escaped="${pat//\'/${_sq}}"
      cat > "$GIT_ASKPASS_SCRIPT" <<ASKPASS
#!/usr/bin/env bash
case "\$1" in
  Username*) printf '%s\n' 'x-access-token' ;;
  *)         printf '%s\n' '${pat_escaped}' ;;
esac
ASKPASS
      export GIT_ASKPASS="$GIT_ASKPASS_SCRIPT"
      # askpass 経由以外の対話プロンプトへのフォールバックを禁止する
      export GIT_TERMINAL_PROMPT=0
      CLONE_URL="$(to_plain_https_url "$REPO_URL")"
      unset pat pat_escaped
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
# 6. git clone 実行（手順書 §6 手順6 / §12.1 冪等: 既存なら git pull）
# ============================================================
if [[ -d "${APP_DIR}/.git" ]]; then
  log "既存リポジトリを検出しました。git pull で更新します（冪等）: ${APP_DIR}"
  # 今回の対話で選択した認証方式を pull に反映する。
  # set-url で CLONE_URL（Deploy key=ssh 形式 / PAT=素の https・認証は
  # GIT_ASKPASS の一時スクリプトが応答）へ付け替えてから pull する。
  # credential.helper は無効化し、入力 PAT の既存ヘルパーへの保存を防ぐ。
  # 過去の実行で remote に資格情報が埋め込まれていた場合は、pull 直後の
  # scrub_origin_credentials で除去される。
  # ※ 再実行時に REPO_URL へ別リポジトリの URL を入力した場合、remote は
  #    そのリポへ付け替わる（bootstrap.sh は対話で受けた URL を正とする仕様）。
  git -C "$APP_DIR" remote set-url origin "$CLONE_URL" \
    || die "remote origin の更新に失敗したため中止しました。"
  git -c credential.helper= -C "$APP_DIR" pull --ff-only \
    || die "git pull に失敗したため中止しました。認証・ローカル変更・ブランチを確認してください。"
  ok "リポジトリを更新しました。"
else
  log "リポジトリを clone します: ${APP_DIR}"
  mkdir -p "$(dirname "$APP_DIR")"
  git -c credential.helper= clone "$CLONE_URL" "$APP_DIR" \
    || die "clone に失敗しました。URL・認証（Deploy key / PAT）の登録内容を確認してください。"
  ok "clone が完了しました。"
fi
# remote URL の資格情報掃除。現行の PAT 経路は URL へ PAT を埋め込まない
# （GIT_ASKPASS 方式）ため通常は no-op だが、過去の実行で .git/config に
# https://<PAT>@github.com/... が残置されている場合をここで除去する。
scrub_origin_credentials "$APP_DIR"
unset CLONE_URL
# PAT 認証用の一時 askpass スクリプトは clone / pull 完了時点で用済みのため
# 即削除する（trap EXIT は異常終了時の取りこぼし防止の保険として残す）。
if [[ -n "${GIT_ASKPASS_SCRIPT:-}" ]]; then
  rm -f "$GIT_ASKPASS_SCRIPT"
  unset GIT_ASKPASS GIT_ASKPASS_SCRIPT
fi

readonly INFRA_DIR="${APP_DIR}/infra"
[[ -d "${INFRA_DIR}/ansible" ]] \
  || die "infra/ansible が見つかりません: ${INFRA_DIR}/ansible（リポジトリ構成を確認してください）。"

# ============================================================
# 7. 構築対象
#    本スクリプトは本番サーバー構築専用。
#    ローカル開発環境は bootstrap 対象外（docker compose up で手動起動）。
# ============================================================
readonly DEPLOY_ENV="production"
log "本番環境を構築します（Let's Encrypt / HSTS 有効）。"

# ============================================================
# 8. ドメイン（SERVER_NAME）（手順書 §6 手順8 / 付録B）
# ============================================================
SERVER_NAME="$(ask "公開ドメイン（SERVER_NAME）" "bat.next-code.jp")"
[[ -n "$SERVER_NAME" ]] || die "SERVER_NAME は必須です。"
validate_hostname "公開ドメイン（SERVER_NAME）" "$SERVER_NAME"

# ============================================================
# 9. Let's Encrypt メール / DB パスワード（手順書 §6 手順9 / 付録B）
#    本番では LE が必要。
#    DB パスワードは空欄なら openssl で自動生成（標準出力には出さない）。
# ============================================================
LE_EMAIL="$(ask "Let's Encrypt 用メールアドレス（証明書通知先）" "admin@next-code.jp")"
[[ -n "$LE_EMAIL" ]] || die "本番では Let's Encrypt 用メールが必須です。"
# 形式検証: @ を含み、vars/YAML を壊す引用符を含まないこと
[[ "$LE_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] \
  || die "メールアドレスの形式が不正です。"

# DB パスワード（本番・ローカル共通で必要。空欄なら自動生成）
gen_password() {
  # 英数字 32 文字の強パスワードを生成（記号は .env 取り回しの安全のため除外）
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32
  else
    # head 側から読む形にする。head | 形式だと head の終了時に tr が SIGPIPE で
    # 非ゼロ終了し、set -o pipefail によりスクリプト全体が abort するため。
    head -c 32 < <(tr -dc 'A-Za-z0-9' < /dev/urandom)
  fi
}

# .env.production が存在する再実行では、DB / Redis パスワードを再生成しない。
# app_deploy role は既存の有効な値を維持し、初回構築の中断で残った
# 未設定項目だけを初回生成済みの secrets.env から補完する。
SECRETS_REUSE=0
if [[ -f "${APP_DIR}/.env.production" ]]; then
  SECRETS_REUSE=1
  log "初回構築済みのため機密は既存 .env.production を維持します（${APP_DIR}/.env.production を検出・DB/Redis パスワードの再生成と対話をスキップ）。"
else
  DB_PASSWORD="$(ask_secret "DB パスワード（空欄で自動生成）")"
  if [[ -z "$DB_PASSWORD" ]]; then
    DB_PASSWORD="$(gen_password)"
    ok "DB パスワードを自動生成しました（値は画面に表示しません。生成 .env に保存されます）。"
  else
    # 手入力パスワードはホワイトリスト検証する。secrets.env / .env は素朴な
    # KEY=VALUE 形式のため、引用符・$・バックスラッシュ等が混入すると後段の
    # 展開・パースを壊す（最悪は意図しない解釈が起きる）恐れがある。
    [[ "$DB_PASSWORD" =~ ^[A-Za-z0-9._@%^+=:,!-]+$ ]] \
      || die "DB パスワードに使用できない文字が含まれています（使用可能: 英数字と . _ - @ % ^ + = : , !）。"
  fi
  # DB root パスワードも併せて自動生成（compose の MYSQL_ROOT_PASSWORD 用）
  DB_ROOT_PASSWORD="$(gen_password)"
  # Redis パスワードを自動生成（docker-compose.production.yml の requirepass 必須・#1062 保護-06）
  # 値は対話表示せず secrets.env → .env.production へ ansible 経由で注入される。
  REDIS_PASSWORD="$(gen_password)"
fi

# ============================================================
# 10. SSH: work 公開鍵（手順書 §6 手順10 / §7.1 / 付録B）
#     work ユーザー名は固定 `work`（所有者方針 / v1.8）。
#     公開鍵は複数行（END で終了）または 1 行貼り付けに対応。
# ============================================================
readonly WORK_USER="work"

cat > /dev/tty <<'PUBKEYMSG'

work ユーザーの authorized_keys に登録する【公開鍵】を貼り付けてください（手順書 §7.1）。
  - 1 行（ssh-ed25519 ... のような行）を貼り付け、最後に空行を入力。
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
# 貼り付けられた各行を公開鍵として構文検証する（ssh-keygen による指紋算出）。
# 無効な鍵のまま進むと、完走時の root SSH 自動無効化と併せて work でも
# ログインできない完全ロックアウトに至るため、警告ではなく die で止める。
_valid_pubkeys=0
while IFS= read -r _pubkey_line; do
  [[ -z "$_pubkey_line" ]] && continue
  if ! printf '%s\n' "$_pubkey_line" | ssh-keygen -lf /dev/stdin >/dev/null 2>&1; then
    die "公開鍵として解釈できない行があります（貼り付け内容を確認して再実行してください）: ${_pubkey_line}"
  fi
  _valid_pubkeys=$((_valid_pubkeys + 1))
done <<< "$SSH_PUBKEYS"
(( _valid_pubkeys > 0 )) \
  || die "有効な公開鍵が 1 本もありません。work ユーザーへのログインに必須です。"
ok "公開鍵 ${_valid_pubkeys} 本の構文検証に合格しました。"

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
# 10c. deploy-bot 用 read-only GitHub Deploy key の生成（G7-R-07）
#
#   方針:
#     - CD（deploy-bot）は git fetch / checkout しか行わない（push しない）ため、
#       deploy-bot が github.com へ接続する際に使う Deploy key は read-only で
#       十分要件を満たす。
#     - 一方、人間運用者（work / root）が github.com へ push する経路では
#       既存の write 許可 Deploy key（/root/.ssh/bat_deploy_key）を継続使用する。
#     - 鍵を分離することで「deploy-bot 侵害時に main へ直接 push されるリスク」
#       を遮断する（G7-R-07）。
#
#   生成物:
#     /root/.ssh/bat_cd_deploy_key       … deploy-bot 用 read-only 秘密鍵
#     /root/.ssh/bat_cd_deploy_key.pub   … 公開鍵（GitHub に Deploy key として
#                                           **read-only** で登録する）
#
#   GitHub 側設定（手順書 §9.1 read-only 追補）:
#     Settings ▸ Deploy keys ▸ Add deploy key
#       ★ Allow write access のチェックは外す（read-only）
#
#   冪等性: 既に /root/.ssh/bat_cd_deploy_key が存在すれば再生成しない。
# ============================================================
readonly DEPLOY_BOT_RO_KEY="/root/.ssh/bat_cd_deploy_key"

if [[ ! -f "$DEPLOY_BOT_RO_KEY" ]]; then
  log "deploy-bot 用 read-only Deploy key を生成します（ed25519・無パスフレーズ）。"
  ssh-keygen -t ed25519 -N "" -C "bat-cd-deploy-key-ro" -f "$DEPLOY_BOT_RO_KEY" >/dev/null
  chmod 600 "$DEPLOY_BOT_RO_KEY"
  chmod 644 "${DEPLOY_BOT_RO_KEY}.pub"
  ok "deploy-bot 用 read-only Deploy key を生成しました: $DEPLOY_BOT_RO_KEY"
  cat > /dev/tty <<RODKMSG

------------------------------------------------------------
${C_WARN}★ deploy-bot 用 read-only Deploy key の登録（G7-R-07）${C_RESET}

以下の【公開鍵】を GitHub の対象リポジトリに **read-only** で登録してください。
  GitHub ▸ 対象リポジトリ ▸ Settings ▸ Deploy keys ▸ Add deploy key
  ★ Allow write access のチェックは入れないこと（read-only 必須）

公開鍵（コピー用・bat-cd-deploy-key-ro）:
$(cat "${DEPLOY_BOT_RO_KEY}.pub")

登録後、Enter を押すと続行します...
------------------------------------------------------------
RODKMSG
  IFS= read -r _ < /dev/tty || true
else
  log "deploy-bot 用 read-only Deploy key は既に存在します: $DEPLOY_BOT_RO_KEY（再生成しません）"
fi

# ============================================================
# （旧 11. バックアップ設定は撤去済み・todo #1188）
#   旧 #665 backup role 向けに GCS バケット名・保持日数を対話収集していたが、
#   所有者方針（2026-07-01・todo #1108）で backup / archive 系が全削除され
#   消費者不在となったため、対話・vars 書き出しごと撤去した。
#   binlog 保持日数は app_deploy role 側の `default(8)` で解決される
#   （roles/app_deploy/tasks/main.yml の bat-binlog.cnf 生成タスク参照）。
# ============================================================

# ============================================================
# 収集値の書き出し（機密はリポ外の生成 config に限定し、権限 600）
#   - vars ファイル: Ansible へ非機密パラメータを渡す（YAML）
#   - secrets env  : 機密（DB パスワード等）を 600 で保存。app_deploy role が .env 生成に使用。
#   ※ 機密は標準出力に出さない / bootstrap.sh にハードコードしない（手順書 §6 末尾の方針）。
# ============================================================
# 生成物はリポジトリ外の /root/.bat-bootstrap/generated に置く。
# リポ内（infra/.generated）に置くと app_deploy role の recurse chown で
# work ユーザー所有となり、機密（secrets.env）の root 専用保護が崩れるため。
# パスは vars の secrets_env_path として Ansible へ渡るので、role 側の変更は不要。
GEN_DIR="/root/.bat-bootstrap/generated"
mkdir -p "$GEN_DIR"
chmod 700 /root/.bat-bootstrap "$GEN_DIR"
# 旧配置（リポ内 infra/.generated）が過去の実行で残っていれば警告する。
# 機密（secrets.env）が work 所有でリポ内に残置され続けるのを防ぐため。
if [[ -e "${INFRA_DIR}/.generated" ]]; then
  warn "旧配置の生成物ディレクトリが残っています: ${INFRA_DIR}/.generated"
  warn "  機密（secrets.env）を含む可能性があります。内容確認のうえ削除を推奨します: rm -rf ${INFRA_DIR}/.generated"
fi

VARS_FILE="${GEN_DIR}/bootstrap_vars.yml"
SECRETS_FILE="${GEN_DIR}/secrets.env"

# --- 本番 TLS モード ---
readonly _use_letsencrypt="yes"
readonly _generate_self_signed="no"
readonly _use_hsts="yes"

# --- 非機密 vars（YAML）。Ansible に --extra-vars で渡す ---
# umask 077 はサブシェルへ閉じ込め、書き出し完了後は元の umask に戻す
# （以降の処理で作られる無関係なファイルまで root 専用権限になるのを防ぐ）。
(
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
# 機密 env ファイルの場所（app_deploy role が読み込んで .env を生成）
secrets_env_path: "${SECRETS_FILE}"
VARS

# --- 機密 env（KEY=VALUE）。app_deploy role が .env 生成に使用 ---
# .env.production がある再実行では、既存資格情報と中断時の復旧用値を
# 保持するため、初回生成済みの secrets.env を書き換えない。
if (( ! SECRETS_REUSE )); then
cat > "$SECRETS_FILE" <<SECRETS
# bootstrap.sh が生成した機密値（権限 600・git 管理外）。
# app_deploy role がこれを基に ${APP_DIR}/.env を生成する想定（手順書 付録A app_deploy）。
DB_PASSWORD=${DB_PASSWORD}
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
SECRETS
fi
)
chmod 600 "$VARS_FILE"
if [[ -f "$SECRETS_FILE" ]]; then
  chmod 600 "$SECRETS_FILE"
fi
# 機密値はメモリ上からも破棄
unset DB_PASSWORD DB_ROOT_PASSWORD REDIS_PASSWORD
ok "対話値を書き出しました（機密は 600 で保護）:"
log "  vars   : ${VARS_FILE}"
if (( SECRETS_REUSE )); then
  log "  secrets: 書き出しなし（初回構築済みのため既存 .env.production の機密を維持）"
else
  log "  secrets: ${SECRETS_FILE}（DB パスワード等。画面には表示しません）"
fi

# ============================================================
# Ansible 実行（手順書 §6 手順9〜 / 付録A の role 群を local connection で適用）
#   site.yml の roles 順: common, swap, users, ssh_hardening, totp,
#                         firewalld, fail2ban, docker, app_deploy
#   ★この時点では ssh_hardening は root 無効化を行わない設計（後述の確認待ち後に適用）。
# ============================================================
# Ansible collections を導入（requirements.yml: ansible.posix の firewalld・community.docker 等）。
# 冪等: requirements.yml 記載の collection がすべて導入済みなら skip する
# （install は毎回ネットワークへ出るため、再実行時の高速化とオフライン耐性のため）。
if [[ -f "${INFRA_DIR}/ansible/requirements.yml" ]]; then
  _installed_collections="$(ansible-galaxy collection list 2>/dev/null || true)"
  _missing_collections=0
  while IFS= read -r _col; do
    [[ -z "$_col" ]] && continue
    grep -q "^${_col} " <<< "$_installed_collections" || _missing_collections=1
  done < <(awk '/^[[:space:]]*- name:/ {print $NF}' "${INFRA_DIR}/ansible/requirements.yml")
  if (( _missing_collections == 0 )); then
    ok "Ansible collections は導入済みです（skip）。"
  else
    log "Ansible collections を導入します（requirements.yml）。"
    ansible-galaxy collection install -r "${INFRA_DIR}/ansible/requirements.yml" \
      || die "ansible-galaxy collection install に失敗しました。ネットワークを確認のうえ bootstrap.sh を再実行するか、手動で 'ansible-galaxy collection install -r ${INFRA_DIR}/ansible/requirements.yml' を実行してから再実行してください。"
  fi
fi

# ============================================================
# Ansible collection の実効版数チェック（playbook 実行前）
#
# requirements.yml の version 範囲指定は ansible-galaxy 経由の導入にしか効かない。
# dnf の ansible バンドル（EPEL 等）は collection を同梱して配置するため、直前の
# 導入ブロックが「名前が既にある」と判定して install を skip すると、範囲外の版が
# そのまま playbook に使われる。実際に範囲外の community.general が使われて
# playbook が即停止した事例があるため、実行前に「ansible が実際に読み込む版」を
# 実測して表示し、範囲外なら対処方法を示して停止する。
#
# ★実効版の求め方（ansible-galaxy collection list の表示順を使わない理由）:
#   ansible は collection 探索パスを先頭から走査し、最初に見つけた 1 つだけを
#   読み込む（先勝ち）。一方 ansible-galaxy collection list の表示順は探索順と
#   一致せず、python パッケージ同梱分（優先度は最下位）が先頭に表示される。
#   表示順の先頭を実効版とみなすと誤判定するため、ここでは ansible-config が
#   返す探索パスを順に走査し、最初に見つかった collection の版を実効版とする。
# ============================================================

# "X.Y.Z" 形式のバージョンを数値比較する。$1 < $2 のとき 0（true）。
# 末尾のプレリリース表記（-rc1 等）は比較対象から落とす。
version_lt() {
  local a="${1%%-*}" b="${2%%-*}"
  local fa fb i x y
  IFS=. read -r -a fa <<< "$a"
  IFS=. read -r -a fb <<< "$b"
  for i in 0 1 2; do
    x="${fa[$i]:-0}"
    y="${fb[$i]:-0}"
    [[ "$x" =~ ^[0-9]+$ ]] || x=0
    [[ "$y" =~ ^[0-9]+$ ]] || y=0
    if (( 10#$x < 10#$y )); then return 0; fi
    if (( 10#$x > 10#$y )); then return 1; fi
  done
  return 1
}

# 実効版 $1 が範囲指定 $2（">=7.0.0,<11.0.0" 形式）を満たすなら 0。
# 解釈できない指定は判定対象外として無視する（誤検知で構築を止めないため）。
version_in_spec() {
  local ver="$1" spec="$2" cons bound
  while IFS= read -r cons; do
    [[ -z "$cons" ]] && continue
    case "$cons" in
      '>='*) bound="${cons#>=}"; if version_lt "$ver" "$bound"; then return 1; fi ;;
      '>'*)  bound="${cons#>}";  if ! version_lt "$bound" "$ver"; then return 1; fi ;;
      '<='*) bound="${cons#<=}"; if version_lt "$bound" "$ver"; then return 1; fi ;;
      '<'*)  bound="${cons#<}";  if ! version_lt "$ver" "$bound"; then return 1; fi ;;
      '=='*) bound="${cons#==}"; if [[ "$ver" != "$bound" ]]; then return 1; fi ;;
      '!='*) bound="${cons#!=}"; if [[ "$ver" == "$bound" ]]; then return 1; fi ;;
      *) : ;;
    esac
  done < <(tr ',' '\n' <<< "$spec")
  return 0
}

# collection ディレクトリ $1 の版数を標準出力へ返す（読めなければ 1 を返す）。
read_collection_version() {
  local dir="$1" ver=""
  if [[ -f "${dir}/MANIFEST.json" ]]; then
    ver="$(awk 'match($0, /"version"[[:space:]]*:[[:space:]]*"[^"]+"/) {
                  s = substr($0, RSTART, RLENGTH)
                  sub(/^"version"[[:space:]]*:[[:space:]]*"/, "", s)
                  sub(/"$/, "", s)
                  print s
                  exit
                }' "${dir}/MANIFEST.json")" || true
  fi
  # galaxy 以外の配置（ソースツリーをそのまま置いた場合）は galaxy.yml を見る
  if [[ -z "$ver" && -f "${dir}/galaxy.yml" ]]; then
    ver="$(awk '$1 == "version:" { print $2; exit }' "${dir}/galaxy.yml" | tr -d "\"'")" || true
  fi
  [[ -n "$ver" ]] || return 1
  printf '%s' "$ver"
}

# collection $1（"namespace.name"）の実効版を "版数<TAB>検出パス" で返す。
# 判定できない場合は何も出力せず 1 を返す。
effective_collection_version() {
  local fqcn="$1"
  local ns="${fqcn%%.*}" name="${fqcn#*.}"
  local search_paths p coll_dir ver

  # ansible-config dump の該当行:
  #   COLLECTIONS_PATHS(default) = ['/root/.ansible/collections', '/usr/share/ansible/collections']
  search_paths="$(ansible-config dump 2>/dev/null \
    | sed -n 's/^COLLECTIONS_PATHS([^)]*) = //p' \
    | tr -d "[]' " | tr ',' '\n')" || true

  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    coll_dir="${p}/ansible_collections/${ns}/${name}"
    [[ -d "$coll_dir" ]] || continue
    # 先勝ちのため、最初に見つかったディレクトリで判定を打ち切る。版数が読めなくても
    # 後続パスへ進まない（進むと優先度の低い版を実効版と誤って報告してしまう）。
    if ver="$(read_collection_version "$coll_dir")"; then
      printf '%s\t%s' "$ver" "$coll_dir"
      return 0
    fi
    return 1
  done <<< "$search_paths"

  # 探索パスのどこにも無い場合、残る供給元は python パッケージ同梱分のみ
  # （優先度は最下位）。この状況では list に出る行も同梱分に限られるため、
  # 最初の該当行をそのまま実効版とみなせる。
  ver="$(ansible-galaxy collection list "$fqcn" 2>/dev/null \
    | awk -v c="$fqcn" '$1 == c { print $2; exit }')" || true
  if [[ -n "$ver" ]]; then
    printf '%s\t%s' "$ver" "python パッケージ同梱"
    return 0
  fi
  return 1
}

# requirements.yml $1 から collection $2 の version 範囲指定を取り出す。
collection_pin_spec() {
  awk -v target="$2" '
    $1 == "-" && $2 == "name:" { current = $3; next }
    $1 == "version:" && current == target {
      v = $0
      sub(/^[[:space:]]*version:[[:space:]]*/, "", v)
      print v
      exit
    }' "$1" | tr -d "\"' "
}

# requirements.yml $1 の全 collection について実効版を表示し、範囲外があれば 1 を返す。
verify_collection_pins() {
  local req_file="$1"
  local fqcn spec ver_path ver path violations=0

  while IFS= read -r fqcn; do
    [[ -z "$fqcn" ]] && continue
    spec="$(collection_pin_spec "$req_file" "$fqcn")" || true
    ver_path="$(effective_collection_version "$fqcn")" || true
    if [[ -z "$ver_path" ]]; then
      warn "  ${fqcn}: 実効版数を判定できませんでした（範囲チェックを skip）。"
      continue
    fi
    ver="${ver_path%%$'\t'*}"
    path="${ver_path#*$'\t'}"
    if [[ -z "$spec" ]]; then
      log "  ${fqcn}: ${ver}（版数指定なし / ${path}）"
    elif version_in_spec "$ver" "$spec"; then
      ok "  ${fqcn}: ${ver}（指定 ${spec} を満たす / ${path}）"
    else
      err "  ${fqcn}: ${ver} は指定範囲 ${spec} を外れています（${path}）"
      violations=$((violations + 1))
    fi
  done < <(awk '$1 == "-" && $2 == "name:" { print $3 }' "$req_file")

  (( violations == 0 ))
}

if [[ -f "${INFRA_DIR}/ansible/requirements.yml" ]]; then
  log "Ansible collection の実効版数を確認します（requirements.yml の指定範囲と照合）。"
  if verify_collection_pins "${INFRA_DIR}/ansible/requirements.yml"; then
    ok "Ansible collection の実効版数チェックを完了しました（指定範囲外の検出なし）。"
  else
    cat >&2 <<PINFAIL

============================================================
★ Ansible collection の版数が requirements.yml の指定範囲から外れています
============================================================

上に [FAIL] で示した collection は、指定範囲の外にある版が「実際に読み込まれる版」
になっています。このまま playbook を実行すると、モジュールの引数・戻り値の非互換に
より構築が途中で停止する可能性があります（過去に範囲外の community.general が
使われて playbook が即停止した事例があります）。

【この範囲指定の意図】
  collection の major 更新はモジュール仕様や戻り値の破壊的変更を伴うことがあります。
  範囲指定は「構築が成功すると分かっている版の幅」に固定し、現地サーバーで同じ構成を
  後から再現できるようにするためのものです。

【なぜ範囲指定が効かないことがあるか】
  範囲指定は ansible-galaxy 経由の導入にのみ効きます。dnf の ansible バンドル
  （EPEL 等）は collection を同梱して配置するため、名前だけが既に存在する状態になり、
  本スクリプトの導入処理が「導入済み」と判断して skip することがあります。
  その場合、同梱された範囲外の版がそのまま使われます。

【入れ替え手順】
  1. 指定範囲の版を優先パスへ導入し直す（推奨）:

       ansible-galaxy collection install -r ${INFRA_DIR}/ansible/requirements.yml --force

     ansible は collection 探索パスを先頭から見て最初に見つけた 1 つを使うため、
     上記で導入した版が同梱版より優先されます。

  2. bootstrap.sh を再実行する（本スクリプトは冪等です）。再実行時に本チェックが
     再度走り、指定範囲に収まっていれば構築が続行されます。

  ※ 1 で解決しない場合は、collection を同梱する ansible バンドルを外し、
     ansible-core と ansible-galaxy 導入分のみの構成へ寄せてください:

       dnf remove ansible     # ansible-core は残ります
       ansible-galaxy collection install -r ${INFRA_DIR}/ansible/requirements.yml

============================================================
PINFAIL
    die "Ansible collection の版数が指定範囲外のため中止しました（上記の入れ替え手順を実施してから再実行してください）。"
  fi
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
#   work の公開鍵を事前検証し、全 role が成功した場合だけ実行する。
#   TOTP は nullok のため、初回構築時は登録なしで公開鍵ログインできる。
# ============================================================
# G7-R-12: hostname -I の重複実行を変数化（NIC 順序変化による結果差異リスク回避）。
# 本変数はこの後の NOTICE 表示と完走時の SERVER_PRIMARY_IP 表示の両方で再利用する。
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')" || SERVER_IP=""
readonly SERVER_IP
cat > /dev/tty <<NOTICE

============================================================
${C_WARN}★ root SSH を自動的に無効化します（手順書 §7.3）${C_RESET}

work ユーザー（${WORK_USER}）へ公開鍵を登録済みです。
TOTP 未登録なら公開鍵だけでログインできます。

  別端末での確認コマンド:
    ssh ${WORK_USER}@${SERVER_IP:-<このサーバーの固定IP>}

  登録済みの場合は TOTP コードも必要です。
  この後 root SSH は自動で無効化されます。
  work でログインできるまで、現在の root セッションを閉じないでください。
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
# 再実行時（.env.production 既存）は secrets.env を生成しないため、
# ファイルが存在する場合のみ削除対話を行う。
if [[ -f "$SECRETS_FILE" ]]; then

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

else
  log "機密ファイル（secrets.env）は今回生成していないため、クリーンアップは不要です。"
fi

# ============================================================
# 完走通知: deploy-bot 秘密鍵を GitHub Secrets PROD_SSH_KEY に登録（v1.8）
#   GitHub Actions (deploy-production.yml) が deploy-bot として SSH ログインし、
#   make deploy-current を実行する。秘密鍵は本サーバー上 (/root/.ssh/bat_cd_key)
#   にも残置されるが、CD 経路は GitHub Secrets 経由が正本。
# ============================================================
# G7-R-12: hostname -I の二度目実行を避け、§10 で取得した SERVER_IP を流用する。
# 同一スクリプト実行中に NIC 順序が変わるケースは想定しないが、変数化により
# 完走通知と root 無効化通知で同一値を返すことを保証する。
SERVER_PRIMARY_IP="${SERVER_IP}"
cat > /dev/tty <<DEPLOYKEYMSG

============================================================
${C_WARN}★ GitHub Secrets PROD_SSH_KEY 登録用の秘密鍵${C_RESET}

GitHub Actions の自動デプロイ用に、以下の秘密鍵を対象リポジトリの
production environment の Secrets に登録してください。
現在の deploy-production は main への push と手動起動に対応しています:

  登録場所 : 対象リポジトリの Settings → Environments → production
  Secret 名: PROD_SSH_KEY
  値       : 下の -----BEGIN OPENSSH PRIVATE KEY----- から
             -----END OPENSSH PRIVATE KEY----- までの全行を貼り付け

----- 秘密鍵（コピー用）-----
$(cat "$DEPLOY_BOT_KEY")
----- 秘密鍵ここまで -----

PROD_HOST / PROD_USER / PROD_HOST_FINGERPRINT も登録してください:
  PROD_HOST: ${SERVER_PRIMARY_IP:-<このサーバーの固定IP>}
  PROD_USER: deploy-bot
  PROD_HOST_FINGERPRINT: 下記で確認した SHA256:... の列

指紋は信頼できるVPS管理コンソールで次を実行して確認してください:
  ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub -E sha256
標準構成はECDSAを使用。ホスト鍵構成を変えた場合はREADMEを参照してください。
未検証のssh-keyscan出力を信頼の根拠にしないでください。
手動ロールバックを使う場合は、production-rollback environment にも
同じ4種類のSecretsを登録し、Required reviewersを構成してください。

秘密鍵ファイルはサーバー上に ${DEPLOY_BOT_KEY} として保存されています
（権限 0600・root 読み取り専用）。

※ 登録完了後は、秘密鍵が画面履歴に残らないよう、この端末の
   スクロールバック（画面の遡り履歴）のクリアを推奨します。
============================================================
DEPLOYKEYMSG

# ============================================================
# PAT 経路の後続更新に関する案内（#1192）
#   PAT は .git/config へ恒久保存しない方針（clone / pull 直後に
#   scrub_origin_credentials で除去）のため、以後の fetch / pull は
#   無認証では通らない。更新手段と CD への影響を完走時に明示しておく
#   （CD 影響の明示は review-1192 重要-2）。
# ============================================================
if [[ "$AUTH_METHOD" == "2" ]]; then
  cat > /dev/tty <<PATNOTE

============================================================
${C_WARN}★ PAT 認証で構築した場合の以後のリポジトリ更新について（#1192）${C_RESET}

入力された PAT はセキュリティ保護のため ${APP_DIR}/.git/config へは
保存していません（clone / pull は一時的な認証応答スクリプト経由で行い、
remote URL へも埋め込みません。スクリプトは使用後に削除済みです）。
このため、以後の git fetch / git pull には改めて認証が必要です:

  1) Deploy key 経路への切替（推奨）: bootstrap.sh を再実行し、
     認証方式で「1) Deploy key」を選択して公開鍵を GitHub に登録
     （remote が git@github.com:... の ssh 形式へ自動で付け替わります）
  2) 再度 PAT を入力: git pull 実行時の Username に GitHub ユーザー名、
     Password に PAT を対話入力する（PAT を URL やコマンドラインへ
     直書きしない・シェル履歴への残置防止）

${C_WARN}★ CD（GitHub Actions 自動デプロイ）への影響${C_RESET}

CD デプロイ（deploy-production.yml）はサーバー上で work ユーザーが
git fetch origin を非対話実行するため、PAT 経路のまま（資格情報なしの
https remote）では恒常的に失敗します。本番運用では Deploy key への
切替が必須です:
  - 推奨: 本スクリプトを再実行して「1) Deploy key」を選択する
    （上記 1 のとおり remote が ssh 化され、非対話 fetch が通ります）
  - または手動で:
    git -C ${APP_DIR} remote set-url origin git@github.com:<owner>/<repo>.git
============================================================
PATNOTE
fi

cat > /dev/tty <<'DONE'

============================================================
  構築フロー完了。次の確認を行ってください（手順書 §11）:
   1) https://<SERVER_NAME>/ へアクセスし証明書と WAF 応答を確認
   2) /healthz が HTTP 200 を返すこと
   3) ssh work@<IP> が公開鍵で成功し、root SSH は拒否されること
      （google-authenticator 登録済みの場合のみ TOTP コードも必要）
   4) 自動デプロイ用に production environment へ
      PROD_SSH_KEY / PROD_HOST / PROD_USER / PROD_HOST_FINGERPRINT を登録
      指紋は信頼できるVPS管理コンソールで次を実行し SHA256:... の列を取得:
      ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub -E sha256
      標準構成はECDSAを使用。ホスト鍵構成を変えた場合はREADMEの手順を参照。
      （ロールバック用 production-rollback にも同じ4種類を登録）
      （main への push と手動起動で deploy-production が実行されます）
   5) 初回管理者ユーザーを作成する（手順書 §10）:
      cd /opt/bat-app
      docker compose --env-file .env.production -f docker-compose.production.yml exec app php artisan bat:create-user
============================================================
DONE
ok "bootstrap.sh を終了します。"
