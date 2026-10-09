---
name: tg-2-write
description: 分析結果に基づいてテストを書き、ゲートを通す
agent: test-writer
argument-hint: 対象ファイル（例 src/RateLimiter.cpp）
---
対象: ${input:target:src/Foo.cpp}

`test-reports/<対象名>/analysis.md` のテスト計画に従ってテストを書いてください（無ければ先に /tg-1-analyze 相当の分析を行う）。

1. シーム無しで書けるテストだけを書く。シームが必要なものは承認されるまで書かない（`.github/testgen/seam-approved` が存在すれば承認済み）。
2. 仕様テストを先に、次に特性テスト。1 回に 5〜15 件。
3. 新しいファイルは `tests/` 配下に作り、テスト用 .vcxproj と .filters に登録する。
4. `run_tests.ps1 -Filter "<Suite>.*"` で動作確認 → 仕様どおりなのに落ちるテストはアサーションを変えずに `DISABLED_` にして bug_suspects.md へ。
5. `gate.ps1` を実行し、FAIL の理由（gate-report.md）に従って修正・削除する。PASS するまで繰り返す。
6. 計画が残っていれば 2 に戻る。
7. 最後に test-writer の報告形式で報告する。
