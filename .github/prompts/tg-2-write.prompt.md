---
name: tg-2-write
description: 分析結果に基づいてテストを書き、ゲートを通す
agent: test-writer
argument-hint: 対象ファイル（例 src/RateLimiter.cpp）
---
対象: ${input:target:src/Foo.cpp}

`test-reports/<対象名>/analysis.md` のテスト計画に従ってテストを書いてください（無ければ先に /tg-1-analyze 相当の分析を行う）。

0. `test-reports/baseline/baseline.md` のモードを確認する。**ミューテーション専用モード**なら、テストを書く前に:
   - スキル `cpp-mutation` に従い、テスト計画の振る舞いを壊すミュータントを `test-reports/mutants/mutants.json` に書く（計画の振る舞い 1 つにつき 1〜2 個）
   - `mutate.ps1` を実行し、`survivors.md` で既存テストが見逃しているものを確認する。**生き残りがある振る舞いを優先して**テストを書く
1. シーム無しで書けるテストだけを書く。シームが必要なものは承認されるまで書かない（`.github/testgen/seam-approved` が存在すれば承認済み）。
2. 仕様テストを先に、次に特性テスト。1 回に 5〜15 件。
3. 新しいファイルは `tests/` 配下に作り、テスト用 .vcxproj と .filters に登録する。
4. `run_tests.ps1 -Filter "<Suite>.*"` で動作確認 → 仕様どおりなのに落ちるテストはアサーションを変えずに `DISABLED_` にして bug_suspects.md へ。
5. ミューテーション専用モードなら `mutate.ps1 -OnlySurvivors` を実行してからゲートへ（ゲートは最新のミューテーション結果で新規テストの価値を判定する）。
6. `gate.ps1` を実行し、FAIL の理由（gate-report.md）に従って修正・削除する。テストを削除・修正した場合、ミューテーション専用モードでは再度 `mutate.ps1 -OnlySurvivors` を実行してからゲートを実行する。PASS するまで繰り返す。
7. 計画が残っていれば 2 に戻る。
8. 最後に test-writer の報告形式で報告する。
