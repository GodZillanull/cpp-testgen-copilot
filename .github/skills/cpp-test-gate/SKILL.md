---
name: cpp-test-gate
description: Build, run and judge Google Test unit tests in this MSVC/.vcxproj C++ repo. Records a baseline, lists uncovered lines with source (when OpenCppCoverage is installed), and runs the acceptance gate (build, 5x shuffled runs, per-test coverage gain or newly caught mutant, no production edits). Works without any coverage tool in mutation-only mode. Use whenever adding, changing or evaluating unit tests, or when asked about test coverage.
---

# C++ テスト検証ゲート（TestGen-LLM 方式）

Meta の TestGen-LLM と同じく、LLM が書いたテストは「候補」として扱い、機械的なフィルタを通ったものだけを残す。
フィルタは: **ビルド成功 → 5 回連続でシャッフル実行しても成功 → ベースラインより測定可能な改善がある**。
判定は必ずスクリプトに任せ、自分の判断で合格とみなさないこと。

## 2 つのモード（`check_env.ps1` と `baseline.md` に表示される）

| モード | 条件 | 「測定可能な改善」の意味 |
|---|---|---|
| **カバレッジモード** | OpenCppCoverage がインストール済み（`coverage.tool` が `auto` / `OpenCppCoverage` / `custom`） | 新規テストが単独で新しい行/分岐を実行する、**または** 既存テストが見逃すミュータントを検出する |
| **ミューテーション専用モード** | カバレッジツールなし（`auto` で未インストール、または `none`）。追加インストール不要 | 新規テストが、既存テストの**どれも検出しない**ミュータントを検出する（Meta ACH 方式） |

ミューテーション専用モードでは `coverage.ps1` は使えない（終了コード 4）。弱点探しは cpp-mutation スキルの `survivors.md` で行い、**テストを書く前にミュータントを作って実行しておく**。

すべてのコマンドはリポジトリのルートで実行する（Windows PowerShell 5.1 / PowerShell 7 どちらでも可）。
スクリプトとこのフォルダの中身は**編集禁止**（フックで拒否される）。設定に問題があればユーザーに `.github/testgen/config.json` の修正を依頼する。

## コマンド

| 目的 | コマンド |
|---|---|
| 環境チェック | `powershell -NoProfile -ExecutionPolicy Bypass -File .github/skills/cpp-test-gate/scripts/check_env.ps1` |
| ベースライン記録（最初に 1 回） | `powershell -NoProfile -ExecutionPolicy Bypass -File .github/skills/cpp-test-gate/scripts/baseline.ps1` |
| ビルド＋テスト（作業中の確認用） | `powershell -NoProfile -ExecutionPolicy Bypass -File .github/skills/cpp-test-gate/scripts/run_tests.ps1 -Filter "FooTest.*"` |
| 未カバー行の一覧（カバレッジモードのみ） | `powershell -NoProfile -ExecutionPolicy Bypass -File .github/skills/cpp-test-gate/scripts/coverage.ps1 -Target src/foo.cpp` |
| **合否判定（ゲート）** | `powershell -NoProfile -ExecutionPolicy Bypass -File .github/skills/cpp-test-gate/scripts/gate.ps1` |

- スクリプト: [check_env.ps1](./scripts/check_env.ps1), [baseline.ps1](./scripts/baseline.ps1), [run_tests.ps1](./scripts/run_tests.ps1), [coverage.ps1](./scripts/coverage.ps1), [gate.ps1](./scripts/gate.ps1), 共通処理 [common.ps1](./scripts/common.ps1)
- 終了コード: 0 = 成功/PASS、1 = 失敗/FAIL、2 = ビルド失敗、3 = 既存テストが失敗（ベースライン取得不可）、4 = カバレッジ無効（ミューテーション専用モード）

## 出力ファイル（すべて `test-reports/` 配下、スクリプトだけが書く）

- `baseline/baseline.json`, `baseline/baseline.md` … 比較の基準。ゲート PASS のたびに自動で前進する
- `coverage/uncovered.md` … 未実行行（`>>`）と分岐が一部だけ通った行（`~~`）をソース付きで表示。**次に書くテストはここから選ぶ**
- `gate/gate-report.md`, `gate/last-gate.json` … ゲートの判定と理由、新規テストごとの寄与

## ゲートの判定基準（gate.ps1）

1. ビルドが通る
2. ベースラインに存在したテストが消えていない・改名されていない
3. 本番コード（`paths.production`）がベースラインから変わっていない（人間が `.github/testgen/seam-approved` を置いた場合のみ許可）
4. 全テストを `--gtest_shuffle` 付きで 5 回実行して全成功（1 回でも落ちたら FLAKY、毎回落ちたら FAILING）
5. 新規テストが**それぞれ単独で**ベースラインに無い行/分岐を実行する（カバレッジモードのみ）、または **ベースラインのどのテストも検出しないミュータント**を検出している（`mutants/results.json`。テストを変更した後は `mutate.ps1 -OnlySurvivors` で結果を更新しないと数えられない）
6. 新規の `DISABLED_` テストは `test-reports/bug_suspects.md` に記載がある

## FAIL のときの直し方

| 理由 | 対応 |
|---|---|
| Build failed | コンパイルエラーを修正。テスト用 .vcxproj への登録漏れ（`<ClCompile Include=...>`）も確認 |
| FAILING | 期待値の根拠を見直す。仕様どおりなのに落ちるなら**アサーションを変えず** `DISABLED_` + bug_suspects.md。根拠が誤りならテストを直す |
| FLAKY | 時刻・乱数・順序・共有状態への依存を除く。直せなければ削除 |
| no coverage gain / catches no new mutant | そのテストを削除する（既存テストと重複している）。残す価値があると考えるなら、そのテストが守る振る舞いのミュータントを mutants.json に追加して `mutate.ps1 -OnlySurvivors` を実行する。それでも新しく検出できなければ削除 |
| Coverage mode changed | 人間に `baseline.ps1` の再実行を依頼する |
| Existing tests were removed | 消したテストを元に戻す |
| Production code changed | 本番コードの変更を元に戻す。シームが必要なら cpp-legacy-seams スキルに従って提案だけ行う |

却下されたテストは**削除して良い**（ベースラインに無い新規テストなので）。同じテストの修正を 3 回試しても通らなければ削除し、報告に含める。

## 注意

- カバレッジモードでも OpenCppCoverage は**行カバレッジのみ**（分岐カバレッジは取れない）。`uncovered.md` の `}` や `else` 行はコンパイラ生成コードの都合で未実行に見えることがあるので無視する。
- ゲートは新規テスト 1 件ごとにカバレッジ計測を行うため、一度に追加するテストは 5〜15 件程度にする。
