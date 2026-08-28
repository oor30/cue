# Cue 技術調査・アーキテクチャ提案

- 作成日: 2026-08-27
- 対象指示書: `docs/cue-development-instructions.md`
- 状態: 実装前レビュー用
- 調査環境: macOS / Xcode 26.6 / Swift 6.3.3 / Codex CLI 0.147.0

## 結論

本システムは技術的に実現可能である。

初期MVPは、macOS 26以降を対象に、ScreenCaptureKitでシステム音声・マイク・画面を別ストリームとして取得し、SpeechAnalyzer / SpeechTranscriberで日本語を端末内文字起こしする構成を推奨する。AI処理は常時実行せず、ローカルのEvent Detectorが候補を検出したときだけCodexへ依頼する。

Codex連携は、Codex CLIを子プロセスとして起動し、`codex app-server --listen stdio://` のJSONL/JSON-RPCインターフェースをProvider内部で利用する案を第一候補とする。会議ごとの状態はCodexセッションではなく、アプリ側のSQLite上のMeeting Stateを正とする。Codexのスレッドは推論の継続性を補助するキャッシュとして扱い、長時間会議ではトピック単位で更新・再作成できるようにする。

重大な実現不能要因は見つかっていない。ただし、実装前に次の4点を決める必要がある。

1. MVPの最低対応OSをmacOS 26にしてよいか。
2. 初期配布をMac App Store外の署名・公証済みアプリとしてよいか。
3. Codex app-serverのexperimentalインターフェースを、バージョン固定と互換アダプター付きで採用してよいか。
4. 会議音声を既定で保存しない方針でよいか。保存しない場合、会議後の高精度な話者再解析は制限される。

---

## 1. 本システムの理解

Cueは議事録生成ツールではなく、会議中の意思決定を支援するリアルタイム・コパイロットである。

中心となる処理は次の閉ループである。

```text
音声・画面
  ↓
文字起こし・画面コンテキスト化
  ↓
ローカルで重要イベント候補を検出
  ↓
現在のMeeting State・直近発言・関連資料を選別
  ↓
必要なときだけCodexで分析
  ↓
短い助言カードを提示
  ↓
決定・TODO・未解決事項としてMeeting Stateを更新
```

品質上の優先順位は次のとおりと理解した。

1. 音声取得と文字起こしを止めない。
2. 会議への集中を妨げない。
3. 根拠のない助言を出さない。
4. 古くなった分析を表示しない。
5. 1時間以上経過しても遅延を累積させない。
6. 対象プロジェクトの既存環境を活用し、二重管理しない。
7. 会議中にソースコードを書き換えない。

議事録・レビューは重要だが、リアルタイム助言の結果を再利用して生成する副次成果物と位置づける。

---

## 2. 推奨アーキテクチャ

### 2.1 全体構成

```text
┌──────────────────────────────────────────────────────────────┐
│ SwiftUI / AppKit                                             │
│ Menu Bar / Right Side Panel / Floating Card / Review         │
└──────────────────────────────┬───────────────────────────────┘
                               │ UI Event
┌──────────────────────────────▼───────────────────────────────┐
│ Meeting Orchestrator actor                                   │
│ Lifecycle / Topic revision / Priority / Cancellation         │
└──────────┬───────────────┬───────────────────┬───────────────┘
           │               │                   │
┌──────────▼──────┐ ┌──────▼─────────┐ ┌───────▼──────────────┐
│ Capture Pipeline │ │ Context Engine │ │ Suggestion Scheduler │
│ Screen/System/Mic│ │ State/Retrieval│ │ Fast/Deep/Dedup      │
└──────────┬──────┘ └──────┬─────────┘ └───────┬──────────────┘
           │               │                   │
┌──────────▼──────┐ ┌──────▼─────────┐ ┌───────▼──────────────┐
│ Transcription    │ │ SQLite / FTS5  │ │ AIProvider           │
│ SpeechAnalyzer   │ │ Evidence Store │ │ CodexProvider         │
└──────────┬──────┘ └────────────────┘ └──────────────────────┘
           │
┌──────────▼───────────────────────────────────────────────────┐
│ Event Detector                                                │
│ Rules / State transition / Candidate scoring / Novelty        │
└───────────────────────────────────────────────────────────────┘
```

### 2.2 設計原則

- Swift Concurrencyの`actor`と`AsyncSequence`を境界に使う。
- キャプチャのコールバック上でOCR、DB、AI処理を行わない。
- ストリームごとに異なるバックプレッシャー方針を持つ。
- DomainモデルをScreenCaptureKit、Speech、Codexの型から独立させる。
- Meeting Stateを唯一の正とし、UIとAIセッションは投影として扱う。
- すべてのAI結果に`meetingID`、`topicRevision`、`sourceEventID`を付ける。
- AI結果を受け取った時点でトピックの関連性を再検証する。
- ファイル更新はAI Providerに行わせず、承認後にアプリ自身が行う。

### 2.3 主なサービス境界

```swift
protocol CaptureService
protocol TranscriptionService
protocol EventDetecting
protocol MeetingStateStore
protocol ProjectRetrievalService
protocol AIProvider
protocol SuggestionScheduling
protocol MeetingRepository
```

`AIProvider`は最低限次を抽象化する。

```text
capabilities
startSession(project, policy)
analyze(request) -> stream of progress/result
cancel(analysisID)
endSession()
```

Codex固有のthread ID、JSON-RPCイベント、CLIのバージョン差は`CodexProvider`から外へ漏らさない。

---

## 3. ScreenCaptureKitを用いた音声・画面取得方式

### 3.1 取得方法

`SCContentSharingPicker.shared`でユーザーに画面、アプリ、ウインドウを選択してもらい、得られた`SCContentFilter`から1本の`SCStream`を構成する。Appleは独自の共有対象ピッカーではなく、システム提供ピッカーの利用を推奨している。

ストリーム出力は次の3種類を別キューへ渡す。

```text
.screen      → 画面フレーム
.audio       → Macのシステム出力音声
.microphone  → 選択したマイク音声
```

設定例の方針は次のとおり。

```text
capturesAudio = true
captureMicrophone = true
excludesCurrentProcessAudio = true
sampleRate = 48,000
channelCount = 1
queueDepth = 3
```

`.microphone`、`captureMicrophone`、`microphoneCaptureDeviceID`はmacOS 15以降で利用できる。システム音声の`.audio`はmacOS 13以降である。実装時はSDKのavailabilityをコード上にも明示する。

### 3.2 音声の扱い

- システム音声とマイクは混ぜずに別系統でSTTへ渡す。
- マイク系統を「自分」、システム音声系統を「自分以外」とみなす。
- 両方の`CMSampleBuffer`のpresentation timestampを共通タイムラインへ正規化する。
- SpeechAnalyzerが要求する形式へ`AVAudioConverter`で変換する。
- マイクのネイティブ形式とシステム音声の指定形式が異なる前提で実装する。
- キャプチャコールバックでは必要最小限のコピーとenqueueだけを行う。

スピーカーから相手音声を再生する場合、マイクにも同じ音が回り込み、二重文字起こしが起きる可能性がある。MVPではヘッドセット利用を推奨し、タイムスタンプとテキスト類似度による重複抑制を入れる。高度な音響エコーキャンセルは別スパイクとする。

### 3.3 画面の扱い

画面解析は動画解析として実装しない。通常は最新フレーム1枚だけを保持し、次の場合に限定して処理する。

- 選択ウインドウまたはアプリが変わった。
- 画面差分が閾値を超えた。
- Event Detectorが画面根拠を必要と判断した。
- ユーザーが「今の画面を確認」を実行した。

画面は低解像度化し、まずVisionによる端末内OCRとアプリ・ウインドウ情報を抽出する。画像そのものをAIへ渡すのは必要時だけとする。Cue自身のパネルはフィルターから除外し、自己キャプチャのループを防ぐ。

既定の「保存しない」では、画像はメモリ上で解析後に破棄する。OCRテキストを会議記録へ保存するかどうかも別設定にする。

### 3.4 権限

少なくとも次が必要になる。

- `NSScreenCaptureUsageDescription`
- `NSMicrophoneUsageDescription`
- Audio Input entitlement
- 初回利用時の画面収録・マイク権限確認

SpeechAnalyzerは音声をAppleのサーバーへ送らないため、`SFSpeechRecognizer`のサーバー認識用権限フローとは分けて扱う。

---

## 4. 推奨STT方式

### 4.1 比較

| 候補 | 長時間会議 | 日本語 | データ送信 | MVP適合性 | 主な懸念 |
|---|---:|---:|---:|---:|---|
| SpeechAnalyzer / SpeechTranscriber | 高い | 対応 | 端末内 | 最有力 | macOS 26以降 |
| SFSpeechRecognizer | 中〜低 | 対応 | 構成によりサーバー利用 | 旧OS用フォールバック | 長時間・再接続設計が必要 |
| whisper.cpp等のローカルモデル | 検証次第 | 対応 | 端末内 | 第二候補 | モデル配布、メモリ、発熱、精度検証 |
| クラウドSTT | サービス依存 | サービス依存 | 外部送信 | 将来Provider | 費用、通信、情報管理 |

### 4.2 推奨

MVPはmacOS 26以降を対象に、`SpeechTranscriber(locale: ja_JP, preset: .progressiveTranscription)`を第一候補とする。

理由は次のとおり。

- Appleが会議・会話・遠距離音声・長時間用途を対象として設計している。
- 暫定結果と確定結果を非同期で受け取れる。
- 端末内処理であり、音声プライバシー上の利点が大きい。
- AssetInventoryでモデルの導入状態を管理できる。
- Swift Concurrencyとの親和性が高い。

このMac上では2026-08-27時点で次を実機確認した。

```text
SpeechTranscriber.isAvailable = true
ja_JP supported = true
ja_JP installed = true
```

システム音声用とマイク用に独立したTranscription Sessionを持ち、結果を同じ会議タイムラインへ統合する。暫定結果はUI表示だけに使い、Meeting State、イベント検出、永続化の主要入力には確定結果を使う。

macOS 15〜25を必須とする場合は、MVPの前に日本語会議音声の同一データセットで`SFSpeechRecognizer`とローカルWhisper系を比較する必要がある。この対応は小さな互換処理ではなく、STT Provider追加として扱う。

---

## 5. Codexとの接続方式

### 5.1 第一候補

アプリからshell文字列を組み立てず、Foundationの`Process`へ実行ファイルURLと引数配列を渡し、次を起動する。

```text
codex app-server --listen stdio://
```

app-serverはJSONLを用いた双方向のJSON-RPC風プロトコルを提供する。接続後は次の順で操作する。

```text
initialize
initialized
thread/start
turn/start
通知をストリーム購読
必要に応じて turn/interrupt
```

採用理由は次のとおり。

- 1プロセスを維持して複数ターンを処理できる。
- threadとturnを明示的に管理できる。
- 進捗通知をストリームで取得できる。
- `outputSchema`でカード形式を制約できる。
- `turn/interrupt`で古いDeep処理を中断できる。
- working directory、sandbox、approval policyを明示できる。
- app-server自体が有界キューとoverloadエラーを持つ。

### 5.2 安定性対策

現在のCLIではapp-server全体がexperimentalと表示される。したがって次を必須とする。

- 対応Codex CLIバージョン範囲をアプリ側で明示する。
- 起動時に`codex --version`を確認する。
- そのCLIから生成したJSON Schemaに対して契約テストする。
- JSON-RPC DTOを`CodexProtocolAdapter`へ隔離する。
- 未知イベントを無視し、必須イベント欠落をタイムアウトで検出する。
- stdoutだけをプロトコルとして扱い、stderrは混ぜない。
- app-serverが利用できない場合の診断をUIへ出す。

### 5.3 フォールバック

最小の疎通確認やapp-server非対応版向けに、次の非対話モードをフォールバックとして残す。

```text
codex exec --json --output-schema ...
codex exec resume --json <thread-id> ...
```

ただしターンごとにプロセスを起動するため、会議中の第一候補にはしない。

### 5.4 認証と環境

- ユーザーの既存Codex認証をCLI自身に利用させる。
- アプリが認証トークンを読み取ったりコピーしたりしない。
- 対象Project Rootを`cwd`として設定する。
- `AGENTS.md`、MCP、Git情報等はCodexの既存探索に任せる。
- 環境変数は必要最小限だけ継承し、ログへ出さない。
- shell経由で起動せず、Project Rootや発言内容によるコマンド注入を防ぐ。

---

## 6. Codexセッションを会議中どのように維持するか

1つのapp-serverプロセスの中で、会議ごとに次の論理スレッドを持つ。

```text
Fast thread
  短い回答・質問・イベント分類用

Deep thread(s)
  調査単位で作成し、終了またはキャンセル可能
```

Fast threadは会議中継続するが、Codex内部履歴を会議状態の正とはしない。会議の正はSQLite上のMeeting Stateである。

運用方針は次のとおり。

- `thread/start`の返却IDをmeeting recordへ保存する。
- アプリ再起動時は可能なら`thread/resume`する。
- ターンごとにMeeting Stateのrevisionとtopic revisionを渡す。
- トピック変更時は進行中のDeep turnを`turn/interrupt`する。
- 使用量または時間が閾値を超えたらFast threadをローテーションする。
- ローテーション時は最新の構造化State Snapshotだけを新threadへ渡す。
- Codexの自動コンパクションだけに依存しない。

Deep Analysisは調査結果がFast会話履歴を汚染しないよう、原則としてイベント単位の短命threadにする。同一論点の再調査だけ同じthreadを再利用する。

---

## 7. 会話全文を毎回渡さずコンテキストを維持する方法

AIへ渡す`MeetingContextEnvelope`を次の固定構造にする。

```text
meeting metadata
current topic + topic revision
structured Meeting State snapshot
直近60〜120秒の確定発言
eventを直接支える発言segment
関連する過去カード
ローカル検索した上位の資料・コード断片
出力制約と期限
```

Meeting Stateは少なくとも次を保持する。

```text
currentTopic
decisions
questions
requirements
unresolvedIssues
actionItems
risks
importantFacts(date, amount, owner, deadline)
previousSuggestions
currentScreenContext
```

### 更新方式

- Transcriptは小さな確定segmentで追記する。
- 暫定segmentは同一IDをrevision更新し、確定後に固定する。
- 5分ごと、トピック切替時、決定検出時にState Snapshotを作る。
- 日付、金額、固有名、決定文は要約だけで失わないよう原文segment IDも保持する。
- 以前の要約を再要約し続けず、構造化項目を差分更新する。
- プロジェクト資料は全文投入せず、`rg`、Git、SQLite FTS5で候補を絞る。

この構成ならCodex threadを失っても、アプリ側Stateから継続できる。

---

## 8. Event Detectorの設計

### 8.1 二段構成

```text
Stage A: Local Candidate Detector
  ルール、状態遷移、重要語、発話終端、画面変化

Stage B: AI Validation / Analysis
  必要な候補だけ分類・調査・カード化
```

Stage Aは確定文字起こしsegmentを入力にする。固定間隔のポーリングではなく、発話確定、トピック変化、画面変化をトリガーとする。

### 8.2 候補検出

MVPでは次の高再現率ルールから始める。

- 質問: 疑問表現、依頼、可否、期限、費用。
- 要望: 「したい」「追加してほしい」「できるように」。
- 決定: 「これで進める」「決まり」「採用する」。
- TODO: 「確認する」「後で送る」「持ち帰る」。
- 重要情報: 日付、時刻、金額、担当、期限。
- リスク: 困難、遅延、セキュリティ、移行、互換性。
- 停滞: 同一topicで未解決状態が一定時間継続し、類似発話が反復。

矛盾と仕様変更は単純なルールだけで確定しない。候補を作り、関連資料・過去決定・コードを検索したうえでAI検証する。

### 8.3 Eventモデル

```text
EventCandidate
- id
- meetingID
- topicID / topicRevision
- type
- sourceSegmentIDs
- triggerReason
- localScore
- noveltyScore
- detectedAt
- state: provisional / validated / dismissed / expired
```

### 8.4 カード過多対策

表示判定は指示書どおり`Importance × Confidence × Novelty`を基本とする。

- 正規化したtype、topic、主要名詞からfingerprintを作る。
- 短時間の同一fingerprintは新規作成せず既存カードを更新する。
- 低重要度はReviewへ保存するだけで会議中表示しない。
- topic revisionが古い結果は破棄する。
- 同時に表示するフローティングカードは原則1枚とする。
- 「質問」「回答」は会話タイミングを逃すため短い有効期限を持たせる。

---

## 9. Fast / Deep処理の設計

### 9.1 Fast

目的は、今すぐ口頭で使える短い助言である。

- 入力は直近発言、State Snapshot、上位数件の根拠だけ。
- 原則1カード、本文2〜4行、詳細は折りたたむ。
- 自由なコード探索や長いWeb検索をさせない。
- strictなJSON Schemaで出力を制約する。
- soft deadlineを約4秒、hard timeoutを約8秒から計測調整する。
- deadlineを超えた回答は現在のtopic revisionと照合し、不要なら表示しない。

### 9.2 Deep

Deepは次を許可する。

- ソースコード・資料・Git履歴の探索。
- 複数仕様案の比較。
- 矛盾、工数、移行、セキュリティリスクの評価。
- Web検索が有効な場合の公式情報確認。

Deep queueの実行並列数は初期値1とし、topicごとに最新1件だけを残す。結果は既存Fastカードへ追記・更新し、同じ論点のカードを増やさない。

### 9.3 自動Deep

次の場合に自動Deep候補とする。

- 確信度が低いが重要度が高い。
- コードまたは公式情報の確認が必要。
- 既存仕様との矛盾候補がある。
- 費用、納期、契約、セキュリティを含む。
- 複数案比較が必要。

会議中は「詳細調査中」を表示できるが、Fastの文字起こしやイベント検出とは完全に別タスクで実行する。

---

## 10. UIアーキテクチャ

SwiftUIを基本にし、macOS固有のウインドウ制御はAppKitを併用する。

### 10.1 ウインドウ

- `MenuBarExtra`: 待機、開始、停止、状態表示。
- 右端サイドパネル: SwiftUIを載せた`NSPanel`。
- 重要通知: フォーカスを奪わない一時的なnon-activating panel。
- Meeting Review: 通常のSwiftUI Window。
- Settings: Project、権限、保存、AI、ショートカット。

### 10.2 状態管理

- `MeetingOrchestrator`はactor。
- UI投影は`@MainActor`のObservable model。
- ViewからCapture、DB、Codexを直接呼ばない。
- カードはIDで差分更新し、タイムライン全体を再構築しない。
- 長いTranscriptはページングし、全件をメモリへ載せない。

### 10.3 UX

- 既定幅は約360〜420ptから実機調整する。
- カードの初期表示はカテゴリ、タイトル、2〜4行、確信度だけ。
- 根拠・複数案・詳細はクリック時に展開する。
- フローティング通知は高重要度のみ、数秒で消す。
- ピン留め、Deep化、非表示を1操作で行える。
- エラーは助言カードと混ぜず、メニューバーの状態で示す。
- Cueのウインドウは画面キャプチャ対象から除外する。

### 10.4 グローバルショートカット

SwiftUIだけでは任意のグローバルショートカットを完結できない。Accessibility権限が必要なCGEventTapは避け、まずCarbon Hot Key APIの薄いラッパーまたは十分に検証された小規模ライブラリを使う案を比較する。ショートカット衝突検知と無効化UIが必要である。

---

## 11. データ保存方式

### 11.1 保存先

初期値は次とする。

```text
~/Library/Application Support/Cue/
├── cue.sqlite
├── Projects/
│   └── <project-id>/
│       └── Meetings/
│           └── <meeting-id>/
│               ├── exports/
│               └── attachments/   # 明示保存時のみ
└── Logs/                           # 内容を含めない診断ログ
```

Project Rootをコピーしない。Project設定にはパスと、必要な配布方式ではsecurity-scoped bookmarkを保存する。

### 11.2 SQLite

SQLiteをWALモードで使用し、明示的なmigrationを持たせる。検索用にFTS5を使う。高頻度のTranscriptは短いトランザクションへまとめて書き込む。

主要テーブル案は次のとおり。

```text
projects
project_paths
meetings
transcript_segments
topics
meeting_state_snapshots
event_candidates
suggestion_cards
evidence
decisions
requirements
action_items
risks
ai_runs
reference_audits
```

### 11.3 重要フィールド

- Transcript: source、speaker、start/end、text、isFinal、revision。
- Topic: revision、started/ended、summary。
- Card: category、title、body、importance、confidence、status、pinned。
- Evidence: kind、path/URL、line、segment ID、file hash、checkedAt。
- AI run: provider、mode、topic revision、latency、status、token usage、web used。

プロンプトやAI応答の全文保存はデバッグ設定でのみ行い、通常ログには秘密情報や会話本文を出さない。

### 11.4 音声・画面

- 画面画像: 既定で保存しない。
- 生音声: 要件が未確定。推奨既定値は保存しない。
- 文字起こし: 保存する。
- 明示的に保存を有効化した場合は、会議単位の削除機能と保存容量表示を必須にする。

---

## 12. ソースコードRead-Onlyを技術的に保証する方法

プロンプトで「変更しない」と指示するだけでは保証にならない。次の防御を重ねる。

### 12.1 Codex実行権限

- threadを`read-only` sandboxで開始する。
- approval policyを`never`にする。
- Meetingモードではファイル変更要求を常に拒否する。
- shellのsandbox escape要求を許可しない。
- Project Rootを文字列連結したshell commandとして実行しない。

### 12.2 MCP・外部ツール

既存MCPを無条件でそのまま有効化することと、無変更保証は両立しない。MCPには外部更新や送信を行うツールが含まれ得るためである。

Meetingモードでは次のいずれかが必要である。

1. 読み取り専用と確認済みのMCP tool名をallowlistする。
2. 初期MVPではMCPを無効化し、必要な読み取り統合を順次許可する。

ツール自身の`readOnlyHint`だけを安全性の根拠にせず、アプリ側設定で確認する。

### 12.3 資料更新

Codexには対象資料も直接書かせない。

```text
Codexが構造化された差分案を返す
  ↓
アプリが許可パス・拡張子・サイズ・変更種別を検証
  ↓
ユーザーがdiffを承認
  ↓
アプリ自身がatomic write
  ↓
readbackして結果表示
```

この方式なら、ソースと資料が同じProject Rootにあっても、Codexへworkspace-write権限を与えずに資料更新を実現できる。

### 12.4 監査

- 会議開始時と終了時にGit statusを記録する。
- 非Git資料も重要ファイルのmetadata/hashを任意監査する。
- file changeイベントが来た場合は異常としてProviderを停止する。
- 監査は防止策の代わりではなく、検知策として扱う。

---

## 13. 長時間会議の負荷対策

### 13.1 キュー方針

| ストリーム | 方針 |
|---|---|
| 音声入力 | 最優先。短い有界リングバッファ。遅延を監視 |
| 確定Transcript | 順序保証。有界キュー。DBへ小刻みにflush |
| 暫定Transcript | 最新版優先。同一segmentの旧revisionを破棄 |
| 画面フレーム | capacity 1。古いフレームを破棄 |
| Event候補 | fingerprintで統合。低優先度を抑制 |
| Fast分析 | topicごとに最新優先。短いdeadline |
| Deep分析 | 並列1、topicごとに最新1件、キャンセル可能 |

音声処理が遅れ始めたら、画面解析、Deep、低重要度イベントの順に停止・間引きする。音声キューを無制限に伸ばして「後で追いつく」設計にはしない。

### 13.2 メモリ

- 全Transcriptを配列で保持しない。
- UIは表示範囲だけページングする。
- 画面は最新1フレームだけ保持する。
- 画像から得たOCR文字列とhashを使い、画像を解放する。
- Meeting Stateは構造化された現在値と定期snapshotだけをメモリへ載せる。
- Codexへ渡すcontextに明確な最大サイズを設ける。

### 13.3 遅延監視

最低限次をメトリクス化する。

```text
audio capture → STT final latency
STT final → event detected latency
event detected → Fast card latency
Deep queue wait / execution time
各queue depth / drop count
DB write latency
Codex timeout / cancel / stale discard count
```

### 13.4 受け入れ試験

- 2時間の録音fixtureを1倍速で流すsoak test。
- 画面差分とイベント候補を同時発生させる。
- Deepを意図的に遅延させてもSTT遅延が増えないことを確認する。
- メモリ使用量が時間に比例して増え続けないことを確認する。
- topic変更後の古いDeep結果が表示されないことを確認する。
- Codex停止、ネット切断、権限取消、音声デバイス切替をfault injectionする。

数値SLOは実機スパイク後に確定する。初期目標は、平常時の確定文字起こしp95を2秒以内、Fastカードp95をイベント確定から5秒以内とし、測定結果に基づき調整する。

---

## 14. MVPの実装順序

### Step 0: 技術スパイク

1. ScreenCaptureKitで`.audio`と`.microphone`を同時取得。
2. 2系統をSpeechAnalyzerへ渡し、日本語暫定・確定結果を確認。
3. 60分以上の連続STTとメモリ・発熱を測定。
4. Codex app-serverのinitialize/thread/turn/interrupt/outputSchemaを確認。
5. read-only sandboxで書き込みが失敗することを統合テスト。

この段階でOS対象、STT、Codex接続の主要リスクを潰す。

### Step 1: アプリ基盤

- macOSアプリ、メニューバー、Settings。
- Project登録とProject Root選択。
- 権限オンボーディング。
- SQLite migration、Meeting lifecycle。
- ログとメトリクス基盤。

### Step 2: Capture / STT縦切り

- 手動会議開始・終了。
- システム音声・マイク・日本語文字起こし。
- 自分／自分以外の表示。
- Transcript保存とReview表示。
- バックプレッシャーと長時間試験。

### Step 3: Event / Meeting State

- 質問、要望、決定、TODO、重要情報。
- 構造化Meeting Stateとtopic revision。
- dedup、novelty、有効期限。

### Step 4: Codex Fast

- CodexProvider。
- read-only policy。
- strict schemaの質問・回答・リスクカード。
- 根拠、確信度、キャンセル、timeout。

### Step 5: Deep / Project Retrieval

- 資料・コード・Gitの検索。
- 矛盾検知、複数仕様案。
- Fastカードの更新。
- stale result抑止。

### Step 6: 会議UI / Review

- 右サイドパネル、フローティング通知。
- pin、Deep化、手動操作。
- 要約、決定、TODO、未回答、Backlog候補の生成。

### Step 7: 品質ゲート

- 2時間soak test。
- 権限、障害、Codex互換性テスト。
- 保存データ削除とreadback。
- CPU、メモリ、遅延の計測。
- 署名・公証した実機ビルド。

### MVPから後続へ送る項目

- Zoom会議開始・終了の完全自動検知。
- 自分以外の高精度な複数話者識別。
- Web自動検索。
- Backlog API登録。
- 資料への承認付き自動反映。
- Claude Code Provider。
- macOS 25以前への対応。
- 組織配布・同期。

---

## 15. 技術的な懸念事項

### 15.1 macOS 26依存

推奨STTはmacOS 26以降である。旧OS対応を同時に行うと、STT Provider、試験条件、権限、品質評価が増える。

### 15.2 話者識別

ScreenCaptureKitで「マイク＝自分」「システム音声＝自分以外」は分離できるが、システム音声内のクライアントA/Bを識別するAPIではない。高精度diarizationは別技術が必要である。

### 15.3 音響回り込み

外部スピーカー会議では相手音声がマイクへ入り、自分の発言として誤認される可能性がある。ヘッドセット、重複抑制、将来のエコーキャンセルを検討する。

### 15.4 Codex接続の互換性

app-serverは要件に適するが、現在のCLIではexperimentalである。バージョン更新時の契約テストとProvider隔離が不可欠である。

### 15.5 Codexの応答時間・利用上限

Fastを数秒以内に必ず返すことはネットワーク、モデル混雑、レート制限に依存する。timeout、劣化表示、ローカルイベントだけで継続できる設計が必要である。

### 15.6 MCPの副作用

既存MCPの全面継承は外部更新・送信リスクを持つ。読み取り専用保証にはtool allowlistが必要である。

### 15.7 App Sandboxと配布

ユーザー環境のCodex CLI、認証、MCP、任意Project Rootをそのまま利用する方式はMac App StoreのApp Sandboxと相性が悪い。初期MVPはDeveloper ID署名・公証による直接配布を推奨する。製品化時はXPC helper、Provider API化、権限設計を再評価する。

### 15.8 画面・音声のプライバシー

画面収録・マイク利用は明示状態、停止、削除、送信データ表示が必要である。顧客会議では参加者への通知・同意も運用要件になる。

### 15.9 保護コンテンツ

DRM等により画面または音声が取得できないコンテンツがあり得る。取得不能を正常な状態として表示する。

### 15.10 Zoom自動検知

Zoomプロセス起動だけでは「会議中」を確実に判定できない。MVPは手動開始を正とし、ウインドウ・音声・プロセス情報による推定後も開始確認を挟む。

### 15.11 グローバルショートカット

任意キーを扱う完全に新しいSwiftUI標準APIはない。使用API、衝突、権限、将来互換性をスパイクで確認する。

### 15.12 AIの確信度

モデルの自己申告値をそのまま表示すると誤解を招く。根拠の有無・品質・一致度をアプリ側で合成し、根拠がない場合は上限を設ける。

---

## 16. 本指示書に対する改善提案

以下は要件を削除する提案ではなく、実装・検証可能な形へ具体化する提案である。

### 提案1: 最低対応OSを明記する

```text
現要件
macOSネイティブアプリ

問題点
推奨STTのSpeechAnalyzerはmacOS 26以降であり、対象OSで構成が変わる。

推奨変更
初期MVPはmacOS 26以降。旧OS対応はSTT Provider追加としてPhase 2以降。

理由
長時間会議向けの端末内STTを最小構成で検証できる。
```

### 提案2: 画面だけでなく生音声の保存既定値を定める

```text
現要件
画面は既定で保存しない。会議後に高精度な話者再解析を許容する。

問題点
音声保存の既定値がなく、保存しなければ会議後の再解析はできない。

推奨変更
生音声も既定では保存しない。再解析を有効にした会議だけ明示保存する。

理由
プライバシーを優先しつつ、必要な案件だけ再解析できる。
```

### 提案3: Source Read-Onlyと資料更新を権限分離する

```text
現要件
ソースはRead-Only、資料は承認後に書き込み可能。

問題点
同じProject RootへCodexのworkspace-writeを与えるとソースも書ける。

推奨変更
Codexは常時Read-Only。差分案を返し、アプリが承認後に許可資料だけ更新する。

理由
技術的に権限を保証でき、監査しやすい。
```

### 提案4: 「既存MCPを利用」と「無変更保証」の優先関係を明記する

```text
現要件
既存MCPを活用し、コード・外部状態を無断変更しない。

問題点
既存MCPには書き込みツールが含まれる可能性がある。

推奨変更
Meetingモードは確認済みRead-Only toolのallowlist方式とする。

理由
既存環境の利便性を保ちつつ、副作用を防げる。
```

### 提案5: リアルタイム性をSLOへ変換する

```text
現要件
数秒以内、1時間以上でも遅延を積み上げない。

問題点
合否判定できる数値がない。

推奨変更
実機スパイク後にSTT p95、Fast card p95、queue depth、memory slopeをSLO化する。

理由
性能劣化を自動テストで検出できる。
```

### 提案6: AIカードに有効期限とtopic revisionを追加する

```text
現要件
古くなった分析を表示しない。

問題点
重要度と確信度だけでは話題変更を判定できない。

推奨変更
全カードへtopicRevision、sourceEventID、expiresAtを持たせる。

理由
遅れて届いた回答を機械的に破棄できる。
```

### 提案7: 確信度の算出規則をデータ化する

```text
現要件
根拠数、品質、コード・Web確認を加味する。

問題点
モデルごとに数値の意味が変わる。

推奨変更
modelConfidenceとは別に、evidenceCoverage、sourceAuthority、agreement、recencyを保存し、表示値をアプリで算出する。

理由
説明可能でテスト可能な確信度になる。
```

### 提案8: 配布方式をPhaseに含める

```text
現要件
将来的に社内配布・製品化。

問題点
App Sandbox、CLI起動、Project Root、認証の方式が配布形態で変わる。

推奨変更
MVPはDeveloper ID直接配布。社内配布前にsandbox/helper/API方式を設計レビューする。

理由
初期検証と製品配布の制約を混同せずに済む。
```

---

## 推奨ディレクトリ構成

実装開始後は、機能別UIとドメイン・インフラの境界を併用する。

```text
cue/
├── Cue.xcodeproj
├── Cue/
│   ├── App/
│   ├── Features/
│   │   ├── Onboarding/
│   │   ├── Projects/
│   │   ├── Meeting/
│   │   ├── Review/
│   │   └── Settings/
│   ├── Domain/
│   │   ├── Models/
│   │   ├── Events/
│   │   └── Policies/
│   ├── Services/
│   │   ├── Capture/
│   │   ├── Transcription/
│   │   ├── EventDetection/
│   │   ├── Context/
│   │   ├── AIProviders/
│   │   │   └── Codex/
│   │   ├── Persistence/
│   │   ├── Permissions/
│   │   ├── HotKeys/
│   │   └── Logging/
│   ├── UIComponents/
│   └── Resources/
├── CueTests/
│   ├── Unit/
│   ├── Integration/
│   ├── Performance/
│   └── Fixtures/
├── docs/
└── scripts/
```

最初から細かいSwift Packageへ分割しすぎず、`Domain`と`CodexProvider`の依存方向をテストで守る。再利用やビルド時間の必要が見えた時点でローカルPackageへ切り出す。

---

## MVP合格条件案

1. 2時間の会議fixtureで文字起こし遅延が時間とともに増えない。
2. システム音声とマイクが「自分以外／自分」として別segmentになる。
3. 暫定結果の修正で重複した確定Transcriptを作らない。
4. 質問、要望、決定、TODOを根拠segment付きで検出できる。
5. Fastカードが短文・根拠・確信度・topic revisionを持つ。
6. topic変更後の古いDeep結果を表示しない。
7. Codexが遅延・停止しても音声取得とSTTが継続する。
8. Codexのファイル書き込みとsandbox escapeが失敗する。
9. 画面画像を保存しない設定で、会議終了後に画像ファイルが残らない。
10. 会議削除後、SQLiteと添付データから対象データをreadbackできない。

---

## 調査根拠

### Apple

- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
- [SCContentSharingPicker](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker)
- [SCStreamConfiguration.capturesAudio](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio)
- [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)
- [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)
- [WWDC25: Bring advanced speech-to-text to your app with SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Requesting authorization to capture and save media](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media)
- [Asking Permission to Use Speech Recognition](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)

### Codex

- [Codex app-server README](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)
- [Codex CLI repository](https://github.com/openai/codex)

### ローカルで確認した事実

- Xcode 26.6、Swift 6.3.3。
- macOS 26.5 SDK上でSpeechAnalyzer / SpeechTranscriberはmacOS 26.0以降。
- ScreenCaptureKitのmicrophone outputはmacOS 15.0以降。
- Codex CLI 0.147.0に`app-server`、`thread/start`、`turn/start`、`turn/interrupt`、`outputSchema`相当のプロトコルが存在する。
- Codex CLI自身から生成したJSON Schemaで上記payloadを確認した。
- 現在のMacでSpeechTranscriberが利用可能で、`ja_JP`がsupportedかつinstalledである。
