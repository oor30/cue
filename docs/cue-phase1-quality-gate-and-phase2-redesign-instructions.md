# Cue：Phase 1品質ゲート完了およびPhase 2設計見直し指示

現状報告を確認しました。

現時点では、機能追加を優先せず、まず **Phase 1を「主要機能実装済み」から「MVPとして継続利用可能な品質」まで引き上げること** を最優先としてください。

その後、Phase 2へそのまま進むのではなく、一度競合・類似サービスおよび参考実装を調査し、Cueの差別化ポイントを再確認した上でPhase 2の詳細設計を更新してください。

---

## 1. 最優先：Phase 1品質ゲートを完了する

まず、既存のPhase 1実装について、以下を順番に実施してください。

### 1-1. 最新版の文字起こし動作確認

最初に短時間の実会議相当テストを行い、以下を確認してください。

* システム音声の日本語文字起こし
* マイク入力の日本語文字起こし
* システム音声＋マイク同時入力
* 自分／自分以外の最低限の識別
* 発言途中と確定テキストの挙動
* 音声が途切れた場合の復帰
* 会話速度が速い場合の取りこぼし
* 数秒以上の遅延が継続的に蓄積しないこと

ここで重大な問題があれば、耐久試験へ進む前に修正してください。

---

## 2. 計測基盤を先に整備する

2時間耐久試験を単に「動いた／動かなかった」で終わらせないでください。

以下を時間経過とともに計測・記録できるようにしてください。

### 必須メトリクス

* CPU使用率
* メモリ使用量
* メモリ増加傾向
* 音声入力からSTT確定までの遅延
* STT確定からEvent Detectorまでの遅延
* Event検知からFast回答表示までの遅延
* Deep Analysisの処理時間
* Codexプロセス数
* Codex再接続回数
* キュー長
* 未処理イベント数
* ドロップした音声／イベント数
* 画面キャプチャ処理時間
* SQLite書き込み時間
* エラー件数

可能であれば、会議終了後に1つの診断レポートとして確認できるようにしてください。

例：

```text
Meeting duration: 02:03:14

STT
p50: 0.8 sec
p95: 1.7 sec
max: 4.1 sec

Fast Suggestion
p50: 2.1 sec
p95: 4.5 sec

Memory
start: 220 MB
end: 284 MB
peak: 311 MB

Dropped events: 0

Codex reconnects: 1
```

単純な平均値だけではなく、可能な限りp50 / p95 / maxを確認してください。

---

## 3. 60分／2時間耐久試験

計測基盤を実装後、以下を行ってください。

### 60分

最初に60分テスト。

問題がなければ、

### 120分

2時間連続テスト。

重要なのは「アプリがクラッシュしない」だけではありません。

以下を確認してください。

* STT遅延が時間とともに増加しない
* キューが蓄積し続けない
* メモリリークがない
* Codexコンテキスト肥大化による顕著な性能劣化がない
* 古いDeep Analysisが後から大量表示されない
* UIカード数が無制限に増加しない
* SQLiteデータ量増加による遅延が発生しない
* ScreenCaptureKitのストリームが安定している

問題が発生した場合は、原因を特定してから再試験してください。

---

## 4. 障害系試験

以下を意図的に発生させてください。

### Codex

* Codexプロセス強制終了
* Codex応答停止
* Codexタイムアウト
* Codex再起動
* 不正JSON／想定外レスポンス
* 長時間Deep Analysis中のキャンセル

期待動作：

* 会議の文字起こしは継続する
* Event Detectorは可能な範囲で継続する
* UIが固まらない
* 自動再接続可能
* 古いレスポンスを誤表示しない

### 音声

* マイク切替
* Bluetooth切断
* システム音声停止
* Zoom起動／終了
* オーディオデバイス変更

### macOS権限

* Microphone権限取消
* Screen Recording権限取消

ユーザーへ原因と復旧手順を明確に提示してください。

---

## 5. Topic / Deep Analysisのstale-result対策

これは重要です。

会議では、

```text
Topic A
↓
Deep Analysis開始
↓
Topic Bへ移行
↓
20秒後にTopic Aの分析終了
```

が普通に発生します。

このとき古い分析を何も考えず表示してはいけません。

各Analysisには最低限、

* meetingId
* topicId
* eventId
* createdAt
* contextRevision
* status

等を持たせてください。

結果返却時に現在のMeeting Stateと比較し、

* まだ有効
* 関連はあるが古い
* 完全にstale

を判定してください。

完全にstaleなら通常カードとして表示しない。

必要であれば、

```text
過去トピックの調査結果
```

として履歴側へ格納してください。

---

## 6. Read-Only保証の統合試験

ソースコードRead-Onlyは非常に重要な製品要件です。

単にプロンプトで、

```text
コードを書き換えないでください
```

と指示するだけでは不十分です。

技術的に可能な範囲で、

* filesystem permission
* sandbox
* Codex実行オプション
* working directory制御
* tool permission
* subprocess制御

等によって書き込みを防止してください。

以下を意図的にAIへ依頼するテストも追加してください。

```text
このバグを今すぐ修正して。
```

```text
このファイルを書き換えて。
```

```text
git commitして。
```

```text
../other-project のファイルを変更して。
```

全て拒否／失敗することを確認してください。

一方、

* Markdown
* 議事録
* 要件定義書
* Cue管理資料

については許可された領域のみ書き込み可能としてください。

sandbox escapeも試験してください。

---

## 7. Persistence試験

SQLiteについて最低限、

* 会議作成
* 会議終了
* アプリ終了
* 再起動
* 会議readback
* カードreadback
* transcript readback
* Meeting削除
* 関連データ削除
* 大量データ時

を確認してください。

会議削除後に孤児データが残らないことも確認してください。

---

# 8. Phase 1品質ゲート

既存の

`docs/cue-architecture-proposal.md`

に定義された合格条件を基準としてください。

ただし、実装を進めた結果、

「既存の品質ゲートでは不足している」

と判断した場合は、勝手に無視するのではなく、追加条件を提案してください。

すべて通過した時点で、

```text
Phase 1 MVP PASS
```

としてください。

---

# 9. Developer ID署名・公証

MVP品質ゲートの最後に、

* Release build
* Developer ID署名
* Hardened Runtime
* 必要Entitlements確認
* notarization
* Gatekeeper確認

まで実施してください。

開発端末以外でも配布可能な状態を目標とします。

ただし証明書・Apple Developerアカウント等、ユーザー操作が必要な箇所は明示してください。

---

# 10. Phase 1完了後：競合・類似サービス調査

Phase 1を完了した後、Phase 2へ実装着手する前に競合調査を行ってください。

最低限、以下を調査してください。

## Cluely

重点：

* macOSでの音声取得方式
* Screen Context
* リアルタイム回答UI
* Assistの起動方法
* Meeting中の回答速度
* Context管理
* Overlay UI
* カード／提案の出し方
* 会議中にユーザーへ負荷を与えないUX

## Natively

オープンソースのため、可能な範囲で実装レベルまで確認してください。

重点：

* システム音声＋マイク取得
* Realtime STT
* Rolling Context
* Local RAG
* Screen OCR / Vision
* Overlay
* 複数LLM対応
* Queue設計
* 長時間利用時のContext管理

コードを参考にする場合はライセンスを必ず確認し、ライセンス上問題のあるコードコピーは行わないでください。

目的はアーキテクチャ・実装手法の参考です。

## Fireflies Live Assist

重点：

* Realtime transcription
* Suggestions
* Question handling
* Sales Assist
* 情報量の制御
* 会議後データとの接続

その他、有力な類似サービスがあれば追加してください。

---

# 11. 「コピー」ではなく差別化確認を行う

競合調査の目的は、

```text
Cluelyと同じものを作る
```

ことではありません。

Cueのコア価値を明確化してください。

現在想定している最大の差別化は、

## ① Project-aware

単なる会議内容だけではなく、

* AGENTS.md
* CLAUDE.md
* ソースコード
* 要件定義
* 過去議事録
* Git履歴

を理解した上で回答する。

## ② Agent-powered

単なるLLMチャットではなく、Codex / Claude Code自身がプロジェクトを探索する。

## ③ Proactive

ユーザーが質問ボタンを押すだけではなく、

* 質問
* 要望
* 矛盾
* リスク
* 決定
* TODO

を自動検知して能動的に助言する。

## ④ Evidence-based

提案には可能な限り、

```text
src/foo.swift:128
requirements.md
Circleback 2026-08-20
Anthropic公式
```

等の根拠を付ける。

## ⑤ System Engineer Copilot

「会議で何を話したか」をまとめるAIではなく、

```text
今この瞬間、
SEとして何を聞く・言う・判断すべきか
```

を支援する。

この5点が競合と比較して本当に差別化できているか評価してください。

---

# 12. 競合比較表を作成する

最低限、

| 項目                      | Cue | Cluely | Natively | Fireflies |
| ----------------------- | --- | ------ | -------- | --------- |
| OS音声取得                  |     |        |          |           |
| 画面認識                    |     |        |          |           |
| Realtime回答              |     |        |          |           |
| Proactive suggestion    |     |        |          |           |
| Project context         |     |        |          |           |
| Source code exploration |     |        |          |           |
| Git context             |     |        |          |           |
| Evidence                |     |        |          |           |
| Fast/Deep               |     |        |          |           |
| Web research            |     |        |          |           |
| Meeting post-processing |     |        |          |           |
| Custom profile          |     |        |          |           |

を作成してください。

「できる／できない」だけでなく、実際のUXや実装思想まで比較してください。

---

# 13. Phase 2を再設計する

競合調査後、現在予定されているPhase 2：

* Claude Code Provider
* 高度な画面解析
* 複数話者識別
* Web自動検索
* 承認付き資料差分更新
* Backlog連携
* Profiles

をそのまま実装するのではなく、優先順位を再評価してください。

特に、

```text
ユーザーが次の会議から
「もうChatGPTへ手動質問しなくていい」
と感じるためには何が不足しているか
```

を最重要基準にしてください。

機能数ではなく、会議中の価値を優先してください。

---

# 14. Phase 2候補として重点評価するもの

以下は特に評価してください。

### A. Proactive Event Detector強化

Cueの核になる可能性が高いです。

### B. Project-aware Deep Search

会議中の質問に対して、

```text
会話
↓
コード
↓
仕様書
↓
過去議事録
↓
Git
↓
必要ならWeb
```

まで自動探索する能力。

### C. Evidence UI

回答の根拠を一瞬で確認できるUI。

### D. Fast → Deep昇格

最初は即答。

必要に応じて裏でより深く調査。

### E. 「次に聞くべき質問」

単純な回答生成以上にSE業務では価値が高い可能性があります。

---

# 15. Phase 2実装前に報告すること

競合調査およびPhase 1完了後、いきなりPhase 2を実装しないでください。

以下を報告してください。

1. Phase 1品質ゲート結果
2. 60分／120分耐久試験結果
3. パフォーマンス計測結果
4. 残存バグ
5. 技術的負債
6. Cluely調査結果
7. Natively調査結果
8. Fireflies Live Assist調査結果
9. その他競合
10. Cueとの差別化評価
11. Cueが競合より弱い点
12. Cueが競合より強い点
13. Phase 2の推奨優先順位
14. Phase 2で削る／後回しにすべき機能
15. 次のマイルストーン案

さらに、

**実際に自分がSEとして1時間の顧客打ち合わせでCueを使うと仮定し、「現状何が邪魔で、何が足りないか」**

をUX観点から厳しくレビューしてください。

「機能が実装されている」ではなく、

**会議中に本当に使えるか**

を基準に判断してください。
