#!/usr/bin/env bash
# rca.sh — 障害解析RCAエージェント起動ラッパ（pi + ICA Opus 4.8）
# 使い方:
#   bash rca.sh <QA情報ファイル> [出力HTMLパス] [ソース探索ディレクトリ]
# 例:
#   cd <ソースリポジトリのルート>
#   bash <repo>/oneshot/rca.sh ./QA_39999.txt
#
# ポイント:
#  - HTMLスケルトンを prompt に「インライン」して渡す（pi -p 単発だと read を省略しがちなため確実にする）
#  - モデルは衝突回避のため完全修飾 ica-bedrock/claude-opus-4-8
#  - ICAは社内プロキシ経由・localhostは no_proxy
#  - テンプレ/スケルトンは本スクリプトからの相対パスで解決（リポジトリ自己完結）
set -euo pipefail

QA_FILE="${1:?QA情報ファイルを指定してください (例: ./QA_39999.txt)}"
OUT="${2:-}"
SRCDIR="${3:-.}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_MD="${RCA_TEMPLATE:-$HERE/prompts/rca.md}"
SKELETON="${RCA_SKELETON:-$HERE/templates/report_skeleton.html}"
MODEL="${RCA_MODEL:-ica-bedrock/claude-opus-4-8}"

export https_proxy="${https_proxy:-http://proxy.apj.ibm.com:8080}"
export http_proxy="${http_proxy:-http://proxy.apj.ibm.com:8080}"
export no_proxy="localhost,127.0.0.1"

[ -f "$QA_FILE" ]     || { echo "QAファイルが見つかりません: $QA_FILE" >&2; exit 1; }
[ -f "$TEMPLATE_MD" ] || { echo "テンプレが見つかりません: $TEMPLATE_MD" >&2; exit 1; }
[ -f "$SKELETON" ]    || { echo "スケルトンが見つかりません: $SKELETON" >&2; exit 1; }

# QA番号を拾って既定の出力名を決める
if [ -z "$OUT" ]; then
  QANO="$(grep -oiE 'QA[番号: ]*[#]?[0-9]+' "$QA_FILE" | grep -oE '[0-9]+' | head -1 || true)"
  OUT="./障害解析報告書_QA${QANO:-XXXX}.html"
fi

# frontmatter(---...---) を除いた本文だけ取り出す
BODY="$(sed '1,/^---$/d' "$TEMPLATE_MD" | sed '1,/^---$/d')"

PROMPT="${BODY}

【今回のQA障害情報】
$(cat "$QA_FILE")

出力先: ${OUT}
ソース探索ディレクトリ: ${SRCDIR}（配下を rg/read で調査すること）

━━━ 出力HTMLの土台（このスケルトンをそのまま使い {{}} を分析結果で置換せよ。CSS改変禁止・独自章立て禁止）━━━
$(cat "$SKELETON")"

echo ">>> RCA解析を開始します（モデル: ${MODEL}）..." >&2
pi -p --no-session --model "$MODEL" "$PROMPT"
echo ">>> 出力: ${OUT}" >&2
