#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
阶段0: 确定性検索 (retrieve.py)
  QA障害情報から検索キーワードを抽出し、ripgrep(rg)でソース内を予備検索して
  「候補ファイル一覧 + ヒット行の前後コンテキスト」を出力する。
  -> モデルの知力に頼らず検索空間を数千ファイルから数ファイルに絞り込む。

使い方:
  python retrieve.py <QAファイル> <ソースdir> [出力json]
出力:
  {出力json} に candidates(ファイル別ヒット) + snippets(前後N行) を保存し、
  人間可読サマリを stdout にも出す。
"""
import sys, os, re, json, subprocess, shutil
from collections import defaultdict

CONTEXT = 12          # ヒット行の前後行数
MAX_FILES = 8         # モデルへ渡す候補ファイル上限
MAX_SNIPPETS_PER_FILE = 6

# 金融固定資産税ドメインの定番シグナル語（日本語/英字/区分値）。
# QA本文から拾えなかった場合の補助にも使う。
DOMAIN_SIGNALS = [
    "件数", "課税標準", "課税標準額", "税額", "評価額", "免税",
    "物件区分", "BUKKEN_KBN", "帳票", "証明書", "償却", "土地", "家屋",
    "COUNT", "KENSU", "ZEI", "KAZEI", "HYOKA", "CHOHYO", "SHOKYAKU",
]

# 検索対象拡張子（Java / PL-SQL 中心）
SRC_GLOBS = ["*.sql", "*.SQL", "*.pkb", "*.pks", "*.prc", "*.fnc",
             "*.java", "*.trg", "*.typ", "*.bdy"]


def rg_path():
    # pi 同梱の rg があれば使う。無ければ PATH の rg。
    cand = os.path.expanduser(
        "~/.pi/agent/bin/rg.exe")
    if os.path.exists(cand):
        return cand
    found = shutil.which("rg")
    return found or "rg"


def extract_keywords(qa_text):
    """QA本文から検索キーワードを抽出する（決定的ルールベース）。"""
    kws = set()

    # 1) 事象・件名に現れるドメイン語
    for sig in DOMAIN_SIGNALS:
        if sig in qa_text:
            kws.add(sig)

    # 2) 英大文字のトークン（関数名・定数名・区分名の候補）
    for m in re.findall(r"[A-Z][A-Z0-9_]{3,}", qa_text):
        kws.add(m)

    # 3) 帳票番号・区分コードらしき数値（2〜4桁）
    for m in re.findall(r"\b(\d{2,4})\b", qa_text):
        # 年度(19xx/20xx)は除外
        if not re.match(r"^(19|20)\d{2}$", m):
            kws.add(m)

    # 4) 「XXが空白」「XXが算出されない」等、症状に紐づく名詞
    for m in re.findall(r"([一-龠ァ-ヶー]{2,10})(?:が|は)(?:常に)?(?:空白|算出されない|0件|表示されない)", qa_text):
        kws.add(m)

    # ノイズ除去
    drop = {"本番機", "環境", "証明", "発行", "設定"}
    return sorted(k for k in kws if k not in drop and len(k) >= 2)


def run_rg(rg, kw, src_dir):
    """1キーワードでrg検索。ヒットした (file, lineno) を返す。"""
    args = [rg, "-n", "--no-heading", "-S"]
    for g in SRC_GLOBS:
        args += ["-g", g]
    args += ["-e", kw, src_dir]
    try:
        out = subprocess.run(args, capture_output=True, text=True,
                             encoding="utf-8", errors="replace", timeout=60)
    except Exception as e:
        return []
    hits = []
    for line in out.stdout.splitlines():
        # 形式: path:lineno:content
        mm = re.match(r"^(.*?):(\d+):(.*)$", line)
        if mm:
            hits.append((mm.group(1), int(mm.group(2)), mm.group(3)))
    return hits


def read_context(path, lineno, ctx=CONTEXT):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except Exception:
        return None
    a = max(0, lineno - 1 - ctx)
    b = min(len(lines), lineno - 1 + ctx + 1)
    seg = []
    for i in range(a, b):
        mark = ">>" if (i + 1) == lineno else "  "
        seg.append(f"{mark}{i+1:5d}| {lines[i].rstrip()}")
    return "\n".join(seg)


def main():
    if len(sys.argv) < 3:
        print("usage: retrieve.py <QAファイル> <ソースdir> [出力json]", file=sys.stderr)
        sys.exit(2)
    qa_file, src_dir = sys.argv[1], sys.argv[2]
    out_json = sys.argv[3] if len(sys.argv) > 3 else "retrieve_result.json"

    qa_text = open(qa_file, encoding="utf-8", errors="replace").read()
    kws = extract_keywords(qa_text)
    rg = rg_path()

    # キーワード別にヒット収集し、ファイル別スコア（ヒット種類数）を集計
    file_score = defaultdict(set)      # path -> set(kw)
    file_hits = defaultdict(list)      # path -> [(lineno, content, kw)]
    for kw in kws:
        for path, lineno, content in run_rg(rg, kw, src_dir):
            file_score[path].add(kw)
            file_hits[path].append((lineno, content, kw))

    # スコア順（マッチしたキーワード種類の多いファイル）で候補を並べる
    ranked = sorted(file_score.items(), key=lambda x: len(x[1]), reverse=True)
    ranked = ranked[:MAX_FILES]

    result = {"qa_file": qa_file, "src_dir": src_dir,
              "keywords": kws, "candidates": []}

    print("=" * 60)
    print(f"[retrieve] キーワード({len(kws)}): {', '.join(kws)}")
    print(f"[retrieve] 候補ファイル({len(ranked)}件):")

    for path, kwset in ranked:
        # ヒット行を行番号順にユニーク化し、代表箇所を抽出
        seen = set()
        hits = sorted(file_hits[path], key=lambda x: x[0])
        snippets = []
        for lineno, content, kw in hits:
            # 近接行はまとめる
            bucket = lineno // (CONTEXT * 2 + 1)
            if bucket in seen:
                continue
            seen.add(bucket)
            ctx = read_context(path, lineno)
            if ctx:
                snippets.append({"lineno": lineno, "matched_kw": kw, "context": ctx})
            if len(snippets) >= MAX_SNIPPETS_PER_FILE:
                break
        rel = os.path.relpath(path, src_dir)
        result["candidates"].append({
            "file": path, "rel": rel,
            "matched_keywords": sorted(kwset),
            "hit_count": len(file_hits[path]),
            "snippets": snippets,
        })
        print(f"   - {rel}  (matched {len(kwset)} kw, {len(file_hits[path])} hits)")

    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    print(f"[retrieve] 出力: {out_json}")
    print("=" * 60)


if __name__ == "__main__":
    main()
