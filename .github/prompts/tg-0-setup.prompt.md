---
name: tg-0-setup
description: テスト生成の準備（環境チェックとベースライン記録）
agent: test-writer
---
テスト生成を始める準備をしてください。コードやテストは書かないでください。

1. スキル `cpp-test-gate` を読み、`check_env.ps1` を実行する。
2. 問題があれば、`.github/testgen/config.json` のどの項目をどう直すべきかを具体的にユーザーに伝えて終了する（config はあなたには編集できません）。
3. 問題がなければ `baseline.ps1` を実行する。既存テストが失敗した場合は、失敗しているテスト名と、`tests.extraArgs` に `--gtest_filter=-壊れたテスト` を設定して除外する案を伝えて終了する。
4. 成功したら `test-reports/baseline/baseline.md` を読み、テスト数・行カバレッジ・カバレッジの低いファイル上位 10 件を報告する。
