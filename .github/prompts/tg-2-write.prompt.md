---
name: tg-2-write
description: 分析結果に基づいて特性テスト・性質テスト（と確認済みの仕様テスト）を書き、ゲートを通す
agent: test-writer
argument-hint: 対象ファイル（例 src/RateLimiter.cpp）
---
対象: ${input:target:src/Foo.cpp}

`test-reports/<対象名>/analysis.md` のテスト計画に従ってテストを書いてください（無ければ先に /tg-1-analyze 相当の分析を行う）。
目的は**現在の動作を固定して、変更で動作が変わったら気づけるようにすること**です。

0. `test-reports/baseline/baseline.md` のモードを確認する。**ミューテーション専用モード**なら、テストを書く前に:
   - スキル `cpp-mutation` に従い、計画の振る舞いを壊すミュータントを `test-reports/mutants/mutants.json` に書く（振る舞い 1 つにつき 1〜2 個）
   - `mutate.ps1` を実行し、`survivors.md` で既存テストが見逃しているものを確認する。**生き残りがある振る舞いを優先して**テストを書く
1. シーム無しで書けるテストだけを書く。シームが必要なものは承認されるまで書かない（`.github/testgen/seam-approved` が存在すれば承認済み）。
2. 書く順番: **特性テスト → 性質テスト → 仕様テスト（根拠が書かれた仕様か、questions.md で「意図どおり」と回答済みのものだけ）**。1 回に 5〜15 件。
3. 特性テストの期待値は推測せず、規約の「特性テストの書き方」に従って**実行して観測した値**を書く（`run_tests.ps1 -Filter "<Suite>.<Test>"` の失敗メッセージ `Which is:` を使う）。
4. 観測した動作が不自然なら、期待値はそのままにして `// 要確認: Q-xxx` を付け、`questions.md` に質問を追加する（既存の質問なら「観測した動作」欄を実測値で更新する）。回答欄は空欄のまま。
5. 新しいファイルは `tests/` 配下に作り、テスト用 .vcxproj と .filters に登録する。
6. `run_tests.ps1 -Filter "<Suite>.*"` で全件通ることを確認する。性質テストが落ちた場合は、性質が成り立たないのか実装の問題かを決めつけず、テストを削除して questions.md に質問として回す。
7. ミューテーション専用モードなら `mutate.ps1 -OnlySurvivors` を実行してからゲートへ。
8. `gate.ps1` を実行し、FAIL の理由（gate-report.md）に従って修正・削除する。テストを削除・修正したら、ミューテーション専用モードでは再度 `mutate.ps1 -OnlySurvivors` を実行してからゲートを実行する。PASS するまで繰り返す。
9. 計画が残っていれば 2 に戻る。
10. 最後に test-writer の報告形式で報告する。**新しく追加した質問の一覧（番号と 1 行要約）**を必ず含め、ユーザーに回答をお願いする。
