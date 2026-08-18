# jip-withai — Java / PL-SQL 障害解析 RCA ワークフロー

金融系（固定資産税など）システムの障害QAに対し、AIエージェント（`pi` coding agent）で
ソースコードを調査し、**バグか否かの判定・直接原因・根本原因・修正案** を
**HTML形式の障害解析報告書** として自動生成するワークフロー一式。

顧客の開発環境が持ち出せない前提のため、QA内容から**模擬コードを作成して効果検証**する運用にも対応する。

---

## 2つの実行方式

| 方式 | ディレクトリ | 想定モデル | 特徴 |
|------|------------|-----------|------|
| **ワンショット** | `oneshot/` | フロンティア級（Opus 4.8 等） | 1回の呼び出しで検索〜分析〜HTML整形まで一気通貫。最高品質。 |
| **分割パイプライン** | `pipeline/` | ローカル中モデル（Qwen3.8-27B ≒ opus4.6 等） | 4段に分割し「工程の確実性」で「モデル知力の不足」を補う。現場ローカル部署向け。 |

> 検証結果：ワンショット(Opus4.8)は全観点を一発で命中。opus4.6は単発だと深い観点（非対称の欠落等）を取りこぼすが、**パイプラインの強制チェックリストを通すと同じopus4.6でも取りこぼしを回収**できた。ローカル7B/8Bは複雑なRCAを単発で完遂できない（→中モデル以上 or パイプライン必須）。

---

## ディレクトリ構成

```
jip-withai/
├── oneshot/                     ワンショット方式（Opus級）
│   ├── rca.sh                   起動ラッパ（テンプレ/スケルトンをインラインしてpiへ）
│   ├── prompts/rca.md           RCA分析プロンプト（分析観点＋出力仕様）
│   └── templates/report_skeleton.html   HTML報告書スケルトン（フル）
│
├── pipeline/                    分割パイプライン方式（ローカル中モデル）
│   ├── rca_27b.sh               4段パイプラインのオーケストレータ
│   ├── retrieve.py              Stage0: 決定的検索（LLM不使用でrg予備検索）
│   ├── prompts/
│   │   ├── stage1_analyze.md    Stage1: 原因分析（必須チェックリストC1-C8, thinking=high）
│   │   ├── stage2_fix.md        Stage2: 修正案（thinking=high）
│   │   └── stage3_render.md     Stage3: HTML整形（thinking=off, 機械合成）
│   └── templates/skeleton_lite.html     軽量HTMLスケルトン
│
├── docs/original_qa/            元となった顧客要件・出力サンプル
│   ├── 金融のプロンプト.txt
│   ├── 2.jpg                    QA明細のサンプル画像
│   └── 障害解析報告書_QA××××.html   出力フォーマットの正解サンプル
│
├── ollama/                      ローカルLLM部署runbook
│   └── qwen3.8-27b-runbook.md   Qwen3.8-27B のOllama部署手順（pipeline方式の実行基盤）
│
└── examples/                    検証用の模擬ケースと生成済み報告書（回帰テスト資産）
    ├── case_shinsa/             主ケース（640行PL/SQL＋QA＋3モデルの報告書比較）
    │   ├── QA_41001.txt
    │   ├── src/01SQL/FUNCTION/PKG_ZEI_CERT_CALC.SQL
    │   ├── 障害解析報告書_QA41001.html            (opus-4-8, ワンショット)
    │   ├── 障害解析報告書_QA41001_opus46.html     (opus-4-6, ワンショット)
    │   └── 障害解析報告書_QA41001_pipeline.html   (opus-4-6, パイプライン)
    └── testcase/                初回の小ケース（QA_39999）
```

---

## 使い方

### 前提
- `pi`（@earendil-works/pi-coding-agent）がインストール済みで、モデルプロバイダが設定済みであること。
  - ICA(Opus/GPT)・ローカルQwen等は `~/.pi/agent/{models,auth,settings}.json` に登録。
  - モデルIDは衝突回避のため **provider/id の完全修飾** で指定（例 `ica-bedrock/claude-opus-4-8`）。
- ICAは社内プロキシ経由（`http://proxy.apj.ibm.com:8080`）、localhostは `no_proxy`。
- 文字コード：PL/SQLはShift-JISの場合あり（日本語コメント文字化けに留意）。

### ワンショット（Opus級）
```bash
cd <解析対象ソースのルート>
bash <repo>/oneshot/rca.sh ./QA_xxxx.txt [出力HTML] [ソース探索dir]
# モデル変更: RCA_MODEL=ica-bedrock/claude-opus-4-8 を環境変数で上書き可
```

### 分割パイプライン（ローカル中モデル）
```bash
bash <repo>/pipeline/rca_27b.sh <QAファイル> <ソースdir> [出力HTML] [モデル]
# 例（現地の27Bに差し替え）:
bash pipeline/rca_27b.sh examples/case_shinsa/QA_41001.txt examples/case_shinsa/src \
     out.html <local-provider>/<qwen3.8-27b>
# 中間生成物は pipeline/_work/ に出る（analysis.json / fix.json / *_raw.txt）
```

---

## パイプライン設計思想（能力の限られたローカルモデル向け）

「フロンティアモデルが賢さで一発でやること」を、中モデルでも**工程の確実性**で再現する。

1. **Stage0 決定的検索**：QAからキーワード抽出→`rg`でソースを予備検索し、数千ファイルを数件に機械的に絞る（大海の一針探しをモデルから取り上げる）。
2. **Stage1 分析（thinking=high）**：必須チェックリストC1〜C8で「全関数で区分は対称に処理されているか」「失敗は例外か黙殺か」「自己点検の対象漏れは」等の深い観点を**強制的に**問う。
3. **Stage2 修正案（thinking=high）**：Stage1のJSONを根拠に変更前後コードを生成。
4. **Stage3 HTML整形（thinking=off）**：2つのJSONを軽量スケルトンへ機械合成。推論させないため様式が崩れない。

---

## 備考
- 生成物は「自動生成（要レビュー）」。行番号・カラム定義・区分格納値は設計書と照合のうえ確定すること。
- 本ワークフローは社内AIプラットフォーム（SOP＋私有ナレッジ）構想の実証も兼ねる。
