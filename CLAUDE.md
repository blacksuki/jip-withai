# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A workflow toolkit for **root-cause analysis (RCA) of Java / PL-SQL faults** in financial-domain systems (fixed-asset tax, etc.). Given a QA fault report, it drives the **`pi` coding agent** (`@earendil-works/pi-coding-agent`, invoked as `pi -p`) to search source code, judge bug-vs-spec, find direct + root cause, propose fixes, and emit a **single self-contained HTML report**.

Key point: **the code here does not perform the analysis itself** — it is orchestration (bash wrappers + prompts + one deterministic retrieval script) that shells out to `pi`. The "product" is the prompt engineering and process design. There is no build/test/lint; validation is by regression against the reports checked into `examples/`.

Docs are written in Japanese/Chinese (domain + team language); mirror the surrounding language when editing prompts, templates, or docs.

## Two execution modes

| Mode | Entry point | Target model | Idea |
|------|-------------|--------------|------|
| **Oneshot** | `oneshot/rca.sh` | Frontier (Opus 4.8) | One `pi` call does search→analyze→HTML end-to-end. |
| **Pipeline** | `pipeline/rca_27b.sh` | Local mid-model (Qwen3.8-27B) | 4 stages; **process certainty compensates for weaker model reasoning**. |

Run oneshot (cwd = the source tree being analyzed):
```bash
bash <repo>/oneshot/rca.sh ./QA_xxxx.txt [out.html] [src_dir]
# override model: RCA_MODEL=ica-bedrock/claude-opus-4-8
```

Run pipeline:
```bash
bash <repo>/pipeline/rca_27b.sh <QA_file> <src_dir> [out.html] [model]
# intermediates land in pipeline/_work/  (retrieve.json / analysis.json / fix.json / *_raw.txt)
```

Regression-check a change by re-running against `examples/case_shinsa/QA_41001.txt` and diffing the HTML against the committed `障害解析報告書_QA41001*.html`.

## Pipeline architecture (`pipeline/`)

The oneshot prompt (`oneshot/prompts/rca.md`) is decomposed into four stages, orchestrated by `rca_27b.sh`:

- **Stage 0 — `retrieve.py` (no LLM):** rule-based keyword extraction from the QA text (domain signal words + `[A-Z_]{4,}` tokens + 2–4 digit codes + symptom nouns), then `rg` over Java/PL-SQL globs, ranks files by number of distinct matched keywords, emits top candidates with ±12-line context to `retrieve.json`. This removes the needle-in-haystack search from the model.
- **Stage 1 — `stage1_analyze.md` (`--thinking high`):** cause analysis, gated by a **mandatory checklist C1–C8** (symmetry of 区分/flag handling across *all* functions, silent-swallow vs throw, NULL/0 propagation, self-check coverage gaps, etc.). The checklist is the forcing device that makes a weaker model surface the deep observations a frontier model finds unprompted. Outputs `analysis.json`.
- **Stage 2 — `stage2_fix.md` (`--thinking high`):** before/after fix proposals grounded in `analysis.json`. Outputs `fix.json`.
- **Stage 3 — `stage3_render.md` (`--thinking off`):** mechanical merge of the two JSONs into the HTML skeleton. Thinking is *off* on purpose so the model doesn't reason and drift from the required format.

Each `pi` call is `--no-session` and single-shot; stages communicate only through the JSON files in `pipeline/_work/`, extracted from fenced ```json blocks by the `extract_json` helper (validates, else keeps raw).

## The output-format contract (strict — do not loosen)

Both modes must produce HTML built **on the checked-in skeleton**, not freshly authored CSS:
- Reuse the skeleton `<style>` (CSS variables + classes) verbatim; fill `{{...}}` placeholders.
- Fixed section order/titles **0–5**: 0 Executive summary (`meta` table + `box box-bad`), 1 Direct cause, 2 Root cause, 3 Fix (paired `<pre class="before">` / `<pre class="after">`), 4 Prevention, 5 Referenced files.
- Fixed class vocabulary: `meta`, `pill{-bad,-warn,-good}`, `box{-bad,-warn,-good}`, `pre.before/.after`, `filepath`. Do not invent class names or sections.
- Skeletons: `oneshot/templates/report_skeleton.html` (full), `pipeline/templates/skeleton_lite.html` (lite).

The wrappers **inline the skeleton into the prompt** rather than trusting the model to `read` it (a `pi -p` single call tends to skip file reads).

## Environment gotchas (Windows / MSYS)

- **Paths:** native Python misreads MSYS `/c/...` paths, so `rca_27b.sh` converts every path handed to Python with `cygpath -m` (→ `C:/...`) via the `towin` helper. Preserve this when adding Python calls.
- **Proxy:** ICA models go through `http://proxy.apj.ibm.com:8080`; `no_proxy=localhost,127.0.0.1` keeps local Ollama direct. Both wrappers set these.
- **Model IDs** must be fully qualified `provider/id` (e.g. `ica-bedrock/claude-opus-4-8`) to avoid collisions; registered in `~/.pi/agent/{models,auth,settings}.json`.
- **Encoding:** PL/SQL sources may be Shift-JIS — Japanese comments can mojibake; readers use `errors="replace"`.
- Generated reports at repo root (`障害解析報告書_*.html`) and `pipeline/_work/` are gitignored; example reports under `examples/` are kept as regression fixtures.

## Known inconsistency

`oneshot/prompts/rca.md` still instructs the agent to `read` a hardcoded skeleton at `C:/Users/MingZhengHuo/workspace/29.JIP/sample/templates/report_skeleton.html` (old `sample/` path). In practice `rca.sh` inlines `oneshot/templates/report_skeleton.html`, so the stale path is inert — but fix the prompt text if you touch it.

## Local LLM deployment

`ollama/qwen3.8-27b-runbook.md` is the runbook for the pipeline's local backend (Qwen3.8-27B on 2×RTX 4090 via Ollama). Two operational must-knows: set `num_ctx` explicitly to 128K+ (Ollama defaults to ~4K and silently truncates long code), and `think`/reasoning depth is a per-request parameter (`high`/`max` for RCA), not fixed at pull time.
