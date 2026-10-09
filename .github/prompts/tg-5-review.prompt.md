---
name: tg-5-review
description: 追加されたテストを独立にレビューする（新しいチャットで実行すること）
agent: test-reviewer
argument-hint: テストファイル（例 tests/RateLimiterTest.cpp）
---
レビュー対象: ${input:tests:tests/FooTest.cpp}

このテストファイルのうち、`test-reports/gate/gate-report.md` とベースライン以降に追加されたテストを、あなたの指示に従って独立にレビューしてください。
テストを書いた側のコメントや報告は根拠にしないでください。
