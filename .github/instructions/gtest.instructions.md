---
description: Google Test / gMock で C++ の単体テストを書くときの規約（特性テストは観測で固定、性質テスト、振る舞い単位、DAMP、決定性）
applyTo: "tests/**/*.{cpp,cc,cxx,h,hpp}"
---

# Google Test 記述規約

根拠: Software Engineering at Google（Unit Testing 章）、Google Testing Blog（DAMP）、GoogleTest 公式ドキュメント、Feathers『Working Effectively with Legacy Code』（特性テスト）、メタモルフィックテスト（オラクルが無い場合の検証）。

## 構成と命名

- 1 テスト = 1 振る舞い。メソッド単位ではなく「何をすると何が起きるか」単位で書く。
- スイート名: 特性テストは `<Class>CharacterizationTest`（既定）、性質テストは `<Class>PropertyTest`、仕様テストは `<Class>Test`。
- テスト名: 振る舞いを表す CamelCase。例: `ReturnsEmptyWhenInputIsBlank`, `ThrowsOnNegativeSize`。
  GoogleTest の制約によりスイート名・テスト名にアンダースコアを使わない（`DISABLED_` 接頭辞のみ例外）。
- 本体は Arrange / Act / Assert の 3 ブロック（Given-When-Then）。空行で区切る。
- 新しいテストファイルは `tests/` 配下に `<Class>Test.cpp` として作り、テスト用 .vcxproj（と .filters）に `<ClCompile Include="..." />` を追加して登録する。

## アサーション

- 結果の**状態**を検証する（戻り値、公開状態、出力）。内部メソッドの呼び出し回数や順序は、それ自体が仕様である場合以外は検証しない。
- 期待値はリテラルで書く。**本番コードと同じ計算式をテスト内で再実装して期待値を作らない**（実装のバグをそのまま写すため）。
- 致命的な前提（null でない、サイズが足りる等）には `ASSERT_*`、それ以外は `EXPECT_*`。
- 浮動小数点は `EXPECT_DOUBLE_EQ` / `EXPECT_NEAR`。文字列は `EXPECT_EQ(std::string, ...)` か `EXPECT_STREQ`。
- 例外は `EXPECT_THROW(stmt, Type)` / `EXPECT_NO_THROW`。メッセージまで仕様なら `EXPECT_THAT` + `testing::HasSubstr`。
- コンテナは `EXPECT_THAT(v, testing::ElementsAre(...))` などのマッチャーを使い、失敗時に差分が読めるようにする。
- 「例外が出ないこと」「クラッシュしないこと」だけを確認するテストは原則書かない（バグを検出できないため）。例外は性質テストの「異常入力で落ちない」で、入力の種類を明示する場合のみ。

## 特性テストの書き方（観測して固定する）

仕様の無いコードでは、期待値を**コードを読んで推測しない**（読み間違えると、存在しない動作を固定してしまう）。Feathers の手順に従う:

1. 入力を決めて、明らかに違う期待値（例: `"__observe__"`、`-12345`）でテストを書く。
2. `run_tests.ps1 -Filter "<Suite>.<Test>"` で実行し、失敗メッセージの `Which is:`（実際の値）を読む。
3. その値を期待値に書き写す。テスト名は観測した動作を表す（`ReturnsAForScore101`）。
4. 観測した動作が不自然なら（境界が非対称、エラーなのに成功値、他の関数と矛盾など）、期待値はそのままにして `// 要確認: Q-xxx` を付け、`questions.md` に質問を追加する。

入力の選び方: 各分岐の境界の両側、0・空・最大値・負数、不正な入力、呼び出し元で実際に渡されている典型値。
1 つの関数に対して特性テストを 1 件だけ書いて終わりにしない（境界の片側だけでは動作の変化を検出できない）。

## 性質テスト（正解が分からなくても書けるテスト）

正解の値は分からなくても、成り立つべき**関係**なら言えることが多い。根拠をコメントに書く。

| 性質 | 例 |
|---|---|
| 往復一致 | `Decode(Encode(x)) == x`、`Parse(Format(v)) == v` |
| 冪等性 | `Normalize(Normalize(s)) == Normalize(s)` |
| 対称性・順序非依存 | `Distance(a, b) == Distance(b, a)`、要素の順番を変えても合計は同じ |
| 単調性 | 入力を増やすと出力が減らない（料金、上限処理など） |
| 関数同士の整合 | `Add` した数と `Count()` が一致、`Contains(x)` と `Find(x) != end` が一致 |
| 不変条件 | 操作後も `Min() <= Max()`、サイズが負にならない |
| 異常入力で落ちない | 空・巨大・不正形式の入力でクラッシュせず、エラーを返す |

- 入力は複数用意し `TEST_P` で回す。乱数は使わず、固定の値の表にする。
- 性質が本当に成り立つか自信が無い場合は、性質テストにせず `questions.md` で確認する。

## 境界値・同値分割

- 各条件分岐について、境界の両側（`limit-1`, `limit`, `limit+1`）、空・ゼロ・最大値、異常系（不正入力、エラー戻り値、例外）を検討する。
- 入力と期待値の表になるものは `TEST_P` + `INSTANTIATE_TEST_SUITE_P` でまとめる（ループで回さない）。

## テストダブル（gMock）

- 可能な限り**本物の依存**を使う。モックは外部 I/O 境界（ファイル、ネットワーク、DB、時刻、乱数、ハードウェア）に限る。
- 自分のコードでないインターフェースを直接モックしない。薄いラッパーを挟む（ただし本番コード変更になるので承認が必要）。
- 基本は `testing::NiceMock`。呼び出し自体が仕様の場合のみ `EXPECT_CALL` で検証し、`StrictMock` は多用しない。
- `#define private public`、`FRIEND_TEST` の新規追加など、非公開部分を覗く手法は使わない。公開 API から検証できない場合は analysis.md でシームを提案する。

## 読みやすさ（DAMP > DRY）

- 各テストは単独で読めること。重要な値はテスト本体に書き、ヘルパーや Fixture に隠さない。
- Fixture（`TEST_F`）は、関係のない準備手順を共通化するためだけに使う。
- コメントは「なぜこの期待値か（仕様の根拠）」を書く。何をしているかの説明は不要。

## 決定性（フレーク禁止）

- `sleep`、実時間、`rand()`、スレッドのタイミング、テスト実行順序、グローバル/static 状態に依存しない。
- 一時ファイルが必要な場合はテストごとに一意なパスを作り、`TearDown` で削除する。
- ゲートは全テストを `--gtest_shuffle` で 5 回実行する。1 回でも落ちれば却下される。

## Windows / MSVC 固有

- Death test（`EXPECT_DEATH`）は Windows では遅く不安定になりやすいので、必要な場合のみ使う。
- 文字列リテラルに日本語を含める場合は、既存テストファイルの文字コード（UTF-8 BOM 付き / Shift_JIS）に合わせる。
