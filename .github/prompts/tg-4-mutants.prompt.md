---
name: tg-4-mutants
description: ミューテーションテストで弱いテストを見つけ、生き残ったバグを捕まえるテストを追加する
agent: test-writer
argument-hint: 対象ファイル（例 src/RateLimiter.cpp）
---
対象: ${input:target:src/Foo.cpp}

スキル `cpp-mutation` を読み、その手順でミューテーションテストを行ってください（Meta ACH 方式）。

1. 対象ファイルについて、現実的で、既存テストでは捕まらなさそうなミュータントを ${input:count:15} 個前後 `test-reports/mutants/mutants.json` に書く（analysis.md の「ミューテーション候補」も参考にする）。
2. `mutate.ps1` を実行し、`survivors.md` を読む。
3. 生き残りごとに、殺すテストを書く（期待値は仕様から）か、根拠を書いて等価とする。迷うものは等価にせず報告に回す。
4. `mutate.ps1 -OnlySurvivors` で殺せたことを確認する。
5. `gate.ps1` を実行し PASS させる。却下されたテストを削除・修正したら、もう一度 `mutate.ps1 -OnlySurvivors` → `gate.ps1` の順に実行する。

ミューテーション専用モード（カバレッジツールなし）では、これが主なテスト追加手順です。1 と 2 を何ラウンドか繰り返し、対象の主要な振る舞い（境界、エラー処理、状態更新）がミュータントで一通り試されるようにしてください。
6. 最初と最後のミューテーションスコア、等価とした数と理由、殺せなかったミュータントを報告する。
