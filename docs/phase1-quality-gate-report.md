# Cue Phase 1 品質ゲート進捗レポート

更新日: 2026-08-28

## 判定

**Phase 1 MVP PASSは未宣言**です。短時間STT、60分／120分耐久、計測基盤、stale-result、Codex障害、Read-Only、Persistence、Release/Hardened Runtimeは確認済みです。音声デバイス／権限の実機fault injection、Developer ID公証が残っています。

## 実施済み

### 短時間の実音声STT

- 入力: 日本語会議録音の45秒区間（開始170秒地点）
- システム音声とマイクを同時にリアルタイム速度で投入
- 両系統とも確定segment 4件、最終結果は46.68秒地点まで継続
- 自分／自分以外は入力系統に基づいて分離
- 暫定更新は両系統で180件超、確定segmentのIDは同一発話内で更新
- 自動復旧遷移0、停止エラー0
- 音声キュー最大2、ドロップ0
- STT確定遅延: p50 0.867秒、p95 1.006秒、max 1.006秒
- CPU peak 0.160%、メモリ 4.032 MB → 10.204 MB（テストプロセス計測）

2026-08-28のPTS修正後に同じ45秒区間を再実行した。

- 両系統投入: system確定4件、microphone暫定33件。microphone確定は同一音声の回り込み抑止により意図どおり非表示
- マイク単独投入: microphone確定4件、最終46.68秒
- 両系統／マイク単独とも自動復旧0、停止0、ドロップ0
- 両系統: キュー最大2、STT p95 0.950秒
- マイク単独: キュー最大1、STT p95 0.945秒

実行例:

```sh
MEETING_COPILOT_STT_FIXTURE='/path/to/audio.m4a' \
MEETING_COPILOT_STT_FIXTURE_START_SECONDS=170 \
MEETING_COPILOT_STT_FIXTURE_SECONDS=45 \
MEETING_COPILOT_STT_FIXTURE_SOURCE=both \
swift test --filter SpeechTranscriptionQualityGateTests
```

### 計測基盤

会議単位で次を収集し、SQLiteへ保存します。会議終了後のレビュー画面とMarkdown書き出しで診断レポートを確認できます。

- CPU p50/p95/max
- メモリ start/end/peak、増加量、1時間換算の増加傾向
- 音声入力→STT確定 p50/p95/max
- STT確定→Event Detector p50/p95/max
- Event→Fastカード p50/p95/max
- Deep Analysis処理時間 p50/p95/max
- Codexプロセス数と再接続回数
- 最大音声キュー長、最大未処理分析数
- 音声／イベントのドロップ数
- 画面OCR処理時間
- SQLite書き込み時間
- エラー件数と直近20件

### 60分耐久試験

- 実時間: 01:00:06
- 日本語会議録音をループし、システム音声・マイクの2系統へ連続投入
- 確定segment: 598件（system 300件、microphone 298件）
- 最終確定位置: 3601.2秒
- STT確定遅延: p50 0.613秒、p95 1.019秒、max 1.091秒
- 音声キュー最大2、ドロップ0
- 文字起こし復旧0、エラー0
- CPU peak 0.123%
- メモリ 4.016 MB → 25.641 MB、peak 25.641 MB、増加21.625 MB
- OS側RSSは6分37.8MB、31分44.6MB、46分43.8MBで、後半は横ばい
- 録音末尾のループを複数回通過してもSTT停止なし

### 120分耐久試験

- 実時間: 02:00:06
- 日本語会議録音をループし、システム音声・マイクの2系統へ連続投入
- 確定segment: 1,201件（system 600件、microphone 601件）
- 最終確定位置: 7197.54秒
- STT確定遅延: p50 0.606秒、p95 1.020秒、max 1.092秒
- 音声キュー最大2、ドロップ0
- 文字起こし復旧0、エラー0
- CPU peak 0.151%
- メモリ 4.016 MB → 29.329 MB、peak 29.329 MB、増加25.313 MB
- メモリ増加傾向: 12.645 MB/時。60分試験の21.587 MB/時より低下
- OS側RSSは5分38.0MB、30分44.5MB、60分52.7MB、75分56.0MB、91分58.4MB、105分60.7MB
- 録音末尾のループを繰り返し通過してもSTT停止なし

### Topic / Deep Analysis stale-result

- 各分析にmeetingID、topicID、eventID、createdAt、contextRevision、mode、statusを保持
- statusはqueued/running/completed/stale/cancelled/timedOut/failed
- current、relatedButOld、staleの3段階で結果返却時に再評価
- 完全staleは通常カードとして表示せず、分析履歴へstaleとして保存
- 同一topic内でcontextだけ古い結果は「過去コンテキスト」と明示し、重要度を抑制
- 明示的な話題遷移表現から新しいtopicIDを発行

### Codex障害系

- 応答停止はRPCタイムアウトで終了
- app-server強制終了時、開始済みturnのwaiterを即時失敗へ遷移
- 不正カードJSONは破棄
- Fast期限超過は`timedOut`としてローカル助言を維持し、Codex接続を再起動しない
- process停止・終了・protocol errorだけを接続障害として1/2/4秒間隔、最大3回で自動再接続
- 会議終了時は進行中分析を先にcancelledへ確定し、`turn/interrupt`を送信
- キャンセル後の遅延結果やエラーでcancelled状態を上書きしない
- 文字起こしとEvent DetectorはCodexセッションから独立

### Read-Only保証

- thread/start: sandbox=`read-only`、approvalPolicy=`never`
- turn/start: sandboxPolicy.type=`readOnly`、approvalPolicy=`never`
- Codex用のApp、Plugin、Browser、Computer Use、Image Generationを無効化
- 専用Codex Homeへread-only/neverを固定し、既存認証だけを参照
- サーバー側からの追加許可要求は常にdenied
- Project Search Policyで許可ルート、除外パス、symlink/traversalを再検証

実Codexに次を依頼する統合試験を実施しました。

1. 既存ファイルの書き換え
2. 新規ファイルの作成
3. git commit
4. `../outside.txt`の書き換え

結果はすべて拒否／失敗し、既存ファイル、外側ファイル、Git HEAD、Git作業ツリーは不変でした。

### Persistence

- 会議作成・終了・再オープンreadback
- transcript/state/event/card/analysis/diagnostics readback
- 500件の確定transcriptを保存・再オープン後に全件取得
- 会議削除後、外部キーcascadeで関連データを削除
- transcript FTSにも削除triggerを追加し、孤児indexを防止

### 自動テスト

- 32テスト、15 suiteを通過（短時間実音声と実Codexのopt-in品質ゲートを除く通常実行）
- 短時間実音声品質ゲートを別途通過
- 実Codex Read-Only品質ゲートを34.634秒で通過

## MVP合格条件の現状

| # | 合格条件 | 状態 | 根拠／残作業 |
|---:|---|---|---|
| 1 | 2時間fixtureでSTT遅延が増えない | PASS | 120分でp95 1.020秒、max 1.092秒、ドロップ0 |
| 2 | system/micを相手／自分として分離 | PASS | 45秒の両系統試験 |
| 3 | 暫定修正で確定Transcriptを重複生成しない | PASS | 発話開始時刻単位の安定IDとupsert |
| 4 | 質問・要望・決定・TODOを根拠付き検出 | PASS | Event Detectorテスト |
| 5 | Fastカードが短文・根拠・確信度・revisionを持つ | PASS | Schemaとモデルテスト |
| 6 | topic変更後の古いDeep結果を表示しない | PASS | stale evaluatorテスト |
| 7 | Codex遅延・停止中もSTT継続 | 一部PASS | 分離設計、timeout/exitテスト済み。実会議中の強制終了を残す |
| 8 | Codex書き込み・sandbox escapeが失敗 | PASS | 実Codex 4要求試験 |
| 9 | 画面画像を保存しない | PASS | 画面frameはOCR後に破棄、画像永続化処理なし |
| 10 | 会議削除後に関連データをreadbackできない | PASS | cascade削除・再読込テスト |

## 残作業

### 耐久試験の再実行方法

同じ試験は`MEETING_COPILOT_STT_SOAK=1`で最大7200秒まで実行でき、fixture末尾では指定開始位置へ戻って連続再生します。実時間でCPU、メモリ、STT遅延、キュー、ドロップを記録し、p95 2秒以下、メモリ増加300 MB以下を自動判定します。

```sh
MEETING_COPILOT_STT_SOAK=1 \
MEETING_COPILOT_STT_FIXTURE='/path/to/audio.m4a' \
MEETING_COPILOT_STT_FIXTURE_START_SECONDS=170 \
MEETING_COPILOT_STT_FIXTURE_SECONDS=3600 \
MEETING_COPILOT_STT_FIXTURE_SOURCE=both \
swift test --filter SpeechTranscriptionQualityGateTests
```

60分・120分ともPASS済みです。120分を再実行する場合は`MEETING_COPILOT_STT_FIXTURE_SECONDS=7200`を指定します。

### 実機fault injection

- 実施手順と合格条件: `docs/phase1-manual-fault-injection-checklist.md`
- マイク入力切替
- Bluetooth切断／再接続
- システム音声停止／復帰
- Zoom起動／終了
- Microphone権限取消／再許可
- Screen Recording権限取消／再許可

失敗時UIには、権限設定、デバイス確認、共有対象再選択、会議再開始の復旧手順を表示します。

### Developer ID署名・公証

Release buildとHardened Runtimeは完了しています。通常テスト32件、Release build、`codesign --verify --deep --strict`を2026-08-28に再実行して成功しました。現在の端末には`Apple Development`証明書だけがあり、`Developer ID Application`証明書がないため、公証とGatekeeper PASSは未実施です。現ビルドはad-hoc + Hardened Runtimeで、署名検証は成功しますがGatekeeperは拒否します。Entitlementsには`com.apple.security.device.audio-input`が含まれています。

Developer ID Application証明書とnotarytool Keychain Profileの準備後、次でRelease build、timestamp付き署名、公証、staple、Gatekeeper評価を一括実行できます。

```sh
CODE_SIGN_IDENTITY='Developer ID Application: ...' \
NOTARYTOOL_PROFILE='cue-notary' \
./scripts/package-and-notarize.sh
```
