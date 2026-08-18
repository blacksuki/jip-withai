#!/usr/bin/env bash
# ============================================================================
# rca_27b.sh — ローカル27B(Qwen3.8-27B 等)向け 分割型 RCA パイプライン
#   opus級モデルの「一発で深く分析＋整形」を、能力の限られたローカルモデルでも
#   再現するため、タスクを4段に分割し「工程の確実性」で「知力の不足」を補う。
#
#   Stage0 決定的検索(retrieve.py) : 9000ファイル -> 候補数件へ機械的に絞込
#   Stage1 原因分析(thinking=high) : 必須チェックリスト付き -> 分析JSON
#   Stage2 修正案  (thinking=high) : 分析JSONを基に -> 修正JSON
#   Stage3 HTML整形(thinking=off)  : 2つのJSON+軽量スケルトンを機械合成 -> HTML
#
# 使い方:
#   bash rca_27b.sh <QAファイル> <ソースdir> [出力HTML] [モデル]
# 例:
#   bash rca_27b.sh case_shinsa/QA_41001.txt case_shinsa/src \
#        case_shinsa/report_27b.html airport/qwen3-vl:8b-instruct
# ============================================================================
set -uo pipefail

QA_FILE="${1:?QAファイルを指定}"
SRC_DIR="${2:?ソースdirを指定}"
OUT="${3:-}"
MODEL="${4:-airport/qwen3-vl:8b-instruct}"   # 現地は ica-bedrock/... or ローカル27B に差し替え

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 原生Windowsパス版（MSYSの /c/... はネイティブpythonが誤変換するため cygpath -m で C:/... に）
HERE_W="$(cygpath -m "$HERE" 2>/dev/null || echo "$HERE")"
PROMPTS="$HERE/prompts"
PROMPTS_W="$HERE_W/prompts"
SKELETON_W="$HERE_W/templates/skeleton_lite.html"
WORK="$HERE/_work"
WORK_W="$HERE_W/_work"
mkdir -p "$WORK"

export no_proxy="localhost,127.0.0.1"
export https_proxy="${https_proxy:-http://proxy.apj.ibm.com:8080}"
export http_proxy="${http_proxy:-http://proxy.apj.ibm.com:8080}"

# 出力名
if [ -z "$OUT" ]; then
  QANO="$(grep -oiE 'QA[番号: ]*[#]?[0-9]+' "$QA_FILE" | grep -oE '[0-9]+' | head -1 || true)"
  OUT="$(dirname "$QA_FILE")/障害解析報告書_QA${QANO:-XXXX}_27b.html"
fi

# ネイティブpythonへ渡す用の原生パス（MSYS /c/... は誤変換されるため cygpath -m）
towin () { cygpath -m "$1" 2>/dev/null || echo "$1"; }
QA_FILE_W="$(towin "$QA_FILE")"
SRC_DIR_W="$(towin "$SRC_DIR")"
OUT_W="$(towin "$OUT")"

# JSONコードフェンスから中身を取り出す小道具（引数は原生パスで渡す）
extract_json () {  # $1=infile(win) $2=outfile(win)
  python - "$1" "$2" <<'PY'
import sys,re,json
raw=open(sys.argv[1],encoding='utf-8',errors='replace').read()
m=re.search(r'```json\s*(.*?)```', raw, re.S) or re.search(r'(\{.*\})', raw, re.S)
txt=(m.group(1) if m else raw).strip()
try:
    obj=json.loads(txt)               # 妥当性チェック
    open(sys.argv[2],'w',encoding='utf-8').write(json.dumps(obj,ensure_ascii=False,indent=2))
    print("OK")
except Exception as e:
    open(sys.argv[2],'w',encoding='utf-8').write(txt)  # 素のまま残す
    print("WARN: not strict json:", e, file=sys.stderr)
PY
}

echo "############################################################"
echo "# RCA 27B pipeline  model=$MODEL"
echo "# QA=$QA_FILE  SRC=$SRC_DIR"
echo "############################################################"

# ---------- Stage0: 決定的検索 ----------
echo ">>> [0/3] 決定的検索 (retrieve.py)"
python "$HERE_W/retrieve.py" "$QA_FILE_W" "$SRC_DIR_W" "$WORK_W/retrieve.json" || { echo "retrieve失敗"; exit 1; }

# ---------- Stage1: 原因分析 (thinking=high) ----------
echo ">>> [1/3] 原因分析 (thinking=high)"
P1="$(cat "$PROMPTS/stage1_analyze.md")

【QA障害情報】
$(cat "$QA_FILE")

【候補ソース（検索で絞込済み: 相対パスと前後行）】
$(cat "$WORK/retrieve.json")

※ ソース探索ディレクトリ: $SRC_DIR （read/rgで実ファイル確認可）"
pi -p --no-session --thinking high --model "$MODEL" "$P1" > "$WORK/stage1_raw.txt" 2>&1
extract_json "$WORK_W/stage1_raw.txt" "$WORK_W/analysis.json"
echo "    -> $WORK/analysis.json"

# ---------- Stage2: 修正案 (thinking=high) ----------
echo ">>> [2/3] 修正案 (thinking=high)"
# 分析JSONをプロンプトへ安全に差し込む（sedはコード混入で壊れるためPythonで）
P2="$(python - "$PROMPTS_W/stage2_fix.md" "$WORK_W/analysis.json" <<'PY'
import sys
tpl=open(sys.argv[1],encoding='utf-8').read()
js=open(sys.argv[2],encoding='utf-8').read()
print(tpl.replace('{{ANALYSIS_JSON}}', js))
PY
)"
P2="$P2

※ ソース探索ディレクトリ: $SRC_DIR （read/rgで実ファイル確認可）"
pi -p --no-session --thinking high --model "$MODEL" "$P2" > "$WORK/stage2_raw.txt" 2>&1
extract_json "$WORK_W/stage2_raw.txt" "$WORK_W/fix.json"
echo "    -> $WORK/fix.json"

# ---------- Stage3: HTML整形 (thinking=off) ----------
echo ">>> [3/3] HTML整形 (thinking=off)"
P3="$(python - "$PROMPTS_W/stage3_render.md" "$WORK_W/analysis.json" "$WORK_W/fix.json" "$SKELETON_W" "$OUT_W" <<'PY'
import sys
tpl=open(sys.argv[1],encoding='utf-8').read()
ana=open(sys.argv[2],encoding='utf-8').read()
fix=open(sys.argv[3],encoding='utf-8').read()
skel=open(sys.argv[4],encoding='utf-8').read()
out=sys.argv[5]
tpl=tpl.replace('{{ANALYSIS_JSON}}',ana).replace('{{FIX_JSON}}',fix)
tpl=tpl.replace('{{SKELETON}}',skel).replace('{{OUT_PATH}}',out)
print(tpl)
PY
)"
pi -p --no-session --thinking off --model "$MODEL" "$P3" > "$WORK/stage3_raw.txt" 2>&1

echo "############################################################"
if [ -f "$OUT" ]; then
  echo "# 完了: $OUT  ($(wc -c < "$OUT") bytes)"
else
  echo "# WARN: HTMLが生成されていない。$WORK/stage3_raw.txt を確認。"
  tail -5 "$WORK/stage3_raw.txt"
fi
echo "# 中間生成物: $WORK/ (analysis.json / fix.json / *_raw.txt)"
echo "############################################################"
