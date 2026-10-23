ECU 時刻同期 PoC: Amazon Time Sync Service と NTP の認証

車両の ECU を Amazon Time Sync Service の時刻に合わせるとき、NTP の通信をどう認証するかを比較する PoC。車両はすでに証明書を持ち、API Gateway と mTLS で通信できる前提に立つ。

前提として確認した事実 (2026-10-22 時点)

AWS 外の機器から使える Amazon Time Sync Service は公開 NTP の time.aws.com で、2022-11-10 に公開された。EC2 ユーザーガイドは用途を次のように書いている。

> For a backup to the local Amazon Time Sync Service on your instances, or to connect resources outside of Amazon EC2 to the Amazon Time Sync Service, you can use the public Amazon Time Sync Service located at time.aws.com.
> https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/set-time.html

公式ドキュメントと What's New には、time.aws.com の NTS (RFC 8915) 対応や対称鍵認証の記述が見つからなかった。この PoC でも time.aws.com の TCP 4460 (NTS-KE) はタイムアウトし、chrony の nts 指定では同期できなかった。比較用の time.cloudflare.com は NTS で同期できたので、クライアント側の問題ではない。

つまり車両が time.aws.com を直接使うと、時刻は認証されない平文 NTP で届く。車両の mTLS 証明書は API Gateway との通信を守るが、NTP の経路には効かない。論点はここにある。

もう一つ押さえておくこと。時刻の改ざんを防ぐうえで必要なのは、車両がサーバーを認証することで、サーバーが車両を認証することではない。時刻は秘密情報ではないからだ。車両証明書による認証は、誰にサーバーを使わせるかというアクセス制御とコストの問題として扱う。

比較した案

A. 平文 NTP で time.aws.com に直接同期する
B. EC2 上に chrony の NTS サーバーを立て、そのサーバーを Amazon Time Sync Service に同期させる。車両は NTS で同期する
C. 対称鍵 NTP。車両ごとの鍵を mTLS の API Gateway から払い出し、EC2 上の chrony と共有する
D. mTLS の API Gateway と Lambda で時刻を返す API を作り、NTP と同じ 4 タイムスタンプ方式でオフセットを計算する
E. ハイブリッド。精度は A の NTP から取り、D の mTLS 時刻と比べてずれが閾値を超えたら NTP の値を捨てる

```
                     ┌──────────────────────── AWS ───────────────────────────┐
                     │                                                         │
 車両                │  [A] time.aws.com (平文 NTP, 認証なし)                   │
 ┌───────────┐ UDP123│                                                         │
 │ TCU       │───────┼─▶ [B][C] NLB ──▶ EC2 chrony (ASG, Multi-AZ)             │
 │ chronyd   │TCP4460│      UDP 123 /    ├─ server 169.254.169.123 (local)      │
 │ 車両証明書│───────┼─▶    TCP 4460     └─ refclock PHC /dev/ptp0 (対応型のみ) │
 └─────┬─────┘       │      (TLS 素通し)                                       │
       │      HTTPS  │                                                         │
       │      mTLS   │  [C][D][E] API Gateway (custom domain + mTLS truststore)│
       └─────────────┼─▶  └─ Lambda: /time (t2,t3), /ntp-key (車両ごとの鍵)    │
       │             │                                                         │
  車内配信 (gPTP 等) └─────────────────────────────────────────────────────────┘
       ▼
  ほかの ECU
```

車両の中では TCU などゲートウェイになる ECU が外部と同期し、ほかの ECU には車載ネットワークで配る形を想定している。車内配信はこの PoC の対象外とした。

B で NLB の TCP 4460 を TLS リスナーにしてはいけない。NTS は TLS セッションから鍵を導出するので、TLS は chrony で終端させる必要がある。NLB の後ろに複数台を置くときは、NTS-KE を受けたサーバーと NTP を受けるサーバーが異なってもクッキーを検証できるよう、全台でサーバー鍵を共有する。chrony では ntsrotate 0 にして鍵ファイルを配り、chronyc rekey で読み直させる。

PoC の構成

finch compose で 5 つのコンテナを立てる。ホストにはポートを公開せず、通信は compose の内部ネットワークで完結する。

| サービス | 役割 | AWS での対応物 |
|---|---|---|
| timesrv | chrony。平文 NTP、対称鍵 NTP、NTS を提供 | EC2 上の chrony |
| rogue | 信頼していない CA の証明書を持つ偽 NTS サーバー | 攻撃者 |
| mitm | NTP 応答の時刻を +3600 秒書き換え、NTS-KE は素通しする | 経路上の攻撃者 |
| api | クライアント証明書必須の HTTPS。/time と /ntp-key。台帳にない CN は 403 | API Gateway + Lambda |
| client | 車両の TCU。chronyd -Q で時計を変えずに測る | 車両 |

ローカルの timesrv は Finch VM の時計をそのまま配っている (local stratum 2)。AWS では config/chrony-server.conf のコメントにある 169.254.169.123 と PHC の設定に差し替える。

```bash
./run-all.sh          # 証明書生成、ビルド、全シナリオ実行。結果は results.txt
finch compose down
```

結果 (2026-10-22, 東京の Mac から実行。results.txt の抜粋)

| シナリオ | 結果 |
|---|---|
| A time.aws.com 平文 (SNTP 8 回の最良値) | offset -0.139 ms, delay 13.251 ms |
| A time.aws.com 平文 (chronyd) | 0.000027 s のずれを検出、同期可 |
| A time.aws.com を nts 指定 | No suitable source。NTS-KE がタイムアウト |
| 参考 time.cloudflare.com を nts 指定 | 同期可 |
| A ローカル平文、MITM 経由 | 3600.000725 s ずれた時刻を受理 |
| B NTS 直結 | 同期可 (0.000121 s) |
| B NTS、MITM 経由 | 改ざんされた応答を破棄し No suitable source |
| B 偽 NTS サーバー | TLS 検証で拒否 (issuer is unknown) |
| C 対称鍵、mTLS で鍵 1001 を取得後に直結 | 同期可 (0.000028 s) |
| C 対称鍵、MITM 経由 | MAC 不一致で破棄 |
| D mTLS /time、VIN001 | 初回 offset +2.005 ms (ハンドシェイク込み)、最良 offset -0.007 ms |
| D 証明書なし、偽 CA の証明書 | TLS で拒否 |
| D 正規証明書だが台帳にない VIN999 | 403 |
| E 正常経路 | NTP と mTLS の差 0.084 ms で NTP を採用 |
| E MITM 経由 | 差 3600 s で NTP を棄却し mTLS 時刻に切り替え |

D では二つの落とし穴を踏んだ。最初の実装は HTTP のヘッダーと本文を別々に送っていたため、Nagle アルゴリズムと遅延 ACK で応答だけが約 40 ms 遅れ、同じ時計を共有しているのに -24 ms のオフセットが出た。TCP_NODELAY で解消した。また TLS ハンドシェイクを含む初回の測定は往復が非対称になり、2 ms 前後ずれる。時刻 API ではハンドシェイク後の keep-alive 上で複数回測り、遅延最小のサンプルを使う必要がある。API Gateway と Lambda を挟むと往復時間が延び、誤差の上限 (往復時間の半分) も広がる。Lambda 実行環境の時計の精度は公開情報で確認できなかったので、AWS 上で実測するまで D の精度は未知数として扱う。

比較

| 観点 | A 平文 | B NTS 自前 | C 対称鍵 | D mTLS 時刻 API | E ハイブリッド |
|---|---|---|---|---|---|
| 改ざん検知 (PoC) | できない | できる | できる | できる | 閾値を超えるずれのみ |
| サーバー認証 | なし | サーバー証明書 | 共有鍵 | サーバー証明書 | D の部分のみ |
| 車両証明書の利用 | なし | なし | 鍵の払い出し時 | 毎リクエスト | D の部分 |
| 精度の見込み | NTP 相当 | NTP 相当 | NTP 相当 | API 往復時間に依存 | NTP 相当 |
| 車両側の実装 | chrony 等そのまま | NTS 対応クライアントが必要 | 鍵の保管と更新 | 独自クライアント | 独自の照合ロジック |
| クラウド側の運用 | なし | EC2 群、NLB、証明書、サーバー鍵共有 | 全サーバーに全車両の鍵 | API Gateway と Lambda | API Gateway と Lambda |
| 車両台数が増えたとき | 影響なし | 影響小 | 鍵配布と失効が破綻しやすい | リクエスト課金が増える | リクエスト課金が増える |

C は PoC では動くが、本番には向かない。chrony の keyfile は静的なファイルで、数十万台分の鍵を全サーバーに配り、失効のたびに rekey させることになる。車両全体で同じ鍵を使えば、1 台から鍵を抜かれただけで全車両向けに偽サーバーを立てられる。

判断

時刻の改ざんを防ぐ必要があるなら B を第一候補にする。標準プロトコルで、車両ごとの鍵管理がなく、PoC で改ざんと偽サーバーの両方を拒否できた。サーバー群は EC2 上で Amazon Time Sync Service のローカルエンドポイントと PHC に同期させる。

EC2 の運用を避けたい場合や、ECU の NTP クライアントが NTS に対応しない場合は E にする。既存の mTLS API Gateway を流用でき、大きな時刻改ざんは検知できる。閾値より小さいずれと、往復時間の半分までずらせる遅延攻撃は検知できない。遅延攻撃は NTS でも防げないので、閾値は D の往復時間と要求精度から決める。

A 単独は、時刻のずれが証明書検証やログの順序を壊しても困らない用途に限る。

どの案でも残る問題がある。B、C、D はいずれも TLS 証明書の有効期間を検証するので、RTC の電池切れなどで車両の時計が大きくずれていると、時刻を取りに行く通信自体が失敗する。chrony には証明書の時刻チェックを無効にする nocerttimecheck がある。ファームウェアのビルド日時を時刻の下限に使うなどの対策と組み合わせて設計する。

AWS 上で次に確かめること

AWS へのデプロイはまだしていない。B は EC2 (PHC 対応インスタンス) と NLB を立て、東京リージョンから LTE 相当の回線で offset と delay を測る。D は API Gateway のカスタムドメインに mTLS の truststore を設定し、Lambda 経由の往復時間と、Lambda の時計と time.aws.com の差を測る。E の閾値はその実測値から決める。

ファイル

```
compose.yaml              コンテナ構成 (ポート公開なし)
Dockerfile                debian bookworm + chrony 4.3 + python3
scripts/gen-certs.sh      PoC 用の CA、サーバー証明書、車両証明書、対称鍵を out/ に生成
config/chrony-server.conf timesrv の設定。AWS 用の同期元をコメントで記載
config/chrony-rogue.conf  偽 NTS サーバーの設定
app/mtls_api.py           API Gateway + Lambda の代役
app/mitm.py               経路上の改ざん役
app/timelib.py            車両側の SNTP と mTLS 時刻取得
app/scenario.py           Python 側のシナリオ
run-all.sh                全シナリオの実行
results.txt               直近の実行結果
```

out/ には PoC 用の秘密鍵が入る。コンテナ内の chronyd が読めるよう権限を 644 にしているので、PoC 以外で使わない。

追加検証: ECS Fargate 上の中継 chrony とディープヘルスチェック (2026-10-22)

中継 chrony の時刻源は、Local Amazon Time Sync Service、time.aws.com、time.cloudflare.com (NTS) の 3 段にした。設定は config/chrony-relay.conf にある。Fargate では CAP_SYS_TIME を追加できず (追加できるのは SYS_PTRACE のみ)、chronyd は -x で時計を動かさずに推定時刻を配る。chronyd のマニュアルは -x について "to operate as an NTP server" と書いている。Fargate のタスクから 169.254.169.123 に届くかは公式ドキュメントに記述がなく、AWS 上で実測するまで未確定とする。

NLB の UDP ターゲットグループは UDP でヘルスチェックできないので、app/healthcheck.py を HTTP で立てる。200 を返すのは、chrony が同期していて、かつ NAT Gateway 経由で time.aws.com か time.cloudflare.com の少なくとも一方に実際に届いたときだけにした。片方の外部サービスが落ちただけで全タスクが不健全になり、NLB が fail open するのを避けるため OR にしている。外部への問い合わせ結果は 5 秒キャッシュする。

```bash
finch compose --profile relay up -d --build
# NAT Gateway 障害の再現: relay のデフォルトルートを消す
finch compose exec relay ip route del default
```

| 状態 | /health |
|---|---|
| 正常 | 200。localsync、time.aws.com 2 台、time.cloudflare.com がすべて到達可 |
| デフォルトルート削除 (NAT Gateway 障害相当) | 503 internet unreachable。chrony 自体は localsync で同期したまま |
| ルート復旧 | 200 |

NLB のヘルスチェック間隔は最短 5 秒、UnhealthyThresholdCount は最小 2 なので、切り離しまでの目安は 10 秒強とキャッシュの 5 秒になる。全 AZ で同時に不健全になると NLB は fail open して全ターゲットに流す点は残る。

追加検証: API Gateway で認証した車両にだけ cookie を払い出す (2026-10-22)

公開の NTP サーバーは置けず、認証が必須という条件での構成。車両は NTS-KE を自分で行わず、mTLS の API Gateway から NTS の鍵と cookie を受け取る。Lambda は NTS pool 拡張 (draft-ietf-ntp-nts-keyexchange-pool-01) の Fixed Key Request を使い、ntpd-rs に自分で生成した C2S 鍵と S2C 鍵を渡して cookie を発行させる。このとき Authentication Token レコード (type 14) でトークンを示す。トークンは Lambda と ntpd-rs だけが持ち、車両には渡らない。ntpd-rs は require-nts = "deny" にして NTS のない NTP を拒否するので、API Gateway を通らなかった相手は時刻を一切得られない。

```
車両 ──mTLS──▶ API Gateway ──▶ Lambda (VPC 内) ──TLS 4460 + トークン + Fixed Key Request──▶ 内部 NLB ──▶ ntpd-rs (どのタスクでもよい)
 │              車両証明書を検証    鍵を生成して cookie を取得
 │◀──── {NLB のホスト名, 鍵, cookie×8} ────┘
 │
 └──UDP 123 NTS──▶ NLB (cross-zone on) ──▶ ECS Managed Instances (複数 AZ、複数タスク)
                                                  タスク: ntpd-rs (時刻源なし、システム時計を配る。マスター鍵は全タスク共通)
                                                        chrony -x (PHC /dev/ptp_ena と 169.254.169.123 で時計のずれを監視)
                                                        ヘルスチェック (時計のずれ、NAT Gateway 経由の到達性)
```

ローカルでの結果 (results-pool.txt)

| シナリオ | 結果 |
|---|---|
| VIN001 が API から取得 | 200、cookie 8 個 |
| その cookie で NTS 付き NTP | 成功。20 回続けても cookie は応答で補充され 8 個のまま。最良 delay 0.091 ms、offset +0.013 ms |
| 台帳にない VIN999 | 403 |
| 偽 CA の証明書、証明書なし | TLS で拒否 |
| 平文 NTP | stratum 0、kiss code DENY |
| でたらめな cookie | kiss code NTSN |
| 誤ったトークンで Fixed Key Request | NTS-KE の Error code 1 (Bad Request) |
| 経路上で時刻を +3600 秒書き換え | 車両側で AES-SIV の検証に失敗し破棄 |
| トークンなしの通常の NTS-KE | cookie 8 個が出る。TCP 4460 は Lambda 以外から届かないようにする必要がある |

設計上の制約

cookie のマスター鍵は全タスクで同じものを使う。ntpd-rs には共有の仕組みがないが、起動時に key-storage-path の鍵ファイルを読むので、Secrets Manager に置いた同じファイルを全タスクに配り、key-rotation-interval を 10 年にしてプロセス内のローテーションを止める。鍵ファイルは scripts/ntpd-keyset.py で作る。形式は ntp-proto/src/keyset.rs の store と load に合わせた非公開の内部形式なので、ntpd-rs の版を固定し、版を上げるときはこの検証をやり直す。これで NLB の cross-zone を有効にしたまま、タスクを何台でも並べられる。

ローテーションは 3 段階のローリングで行う。段階 1 で新しい鍵を足し (primary は旧鍵のまま) 全タスクを入れ替える。段階 2 で新しい鍵を primary にして入れ替える。段階 3 で旧鍵を捨てる。段階 2 の途中でも入れ替え前のタスクは旧鍵の cookie を出すので、車両の手持ちには旧鍵の cookie が混ざる。cookie は 1 回の問い合わせで 1 個ずつ新しいものに替わるので、段階 2 と 3 の間は車両が 8 回以上問い合わせるのに十分な時間を空ける。長く止まっていた車両は段階 3 の後に NTSN を受けるので、車両側は NTSN を受けたらその cookie を捨てて次の cookie で再送し、尽きたら API から取り直す。

| 検証 (results-rotation.txt) | 結果 |
|---|---|
| ntpdrs で発行した cookie を ntpdrs と ntpdrs2 に交互に送る | すべて成功 |
| 段階 1、段階 2 のローリング中に両方へ送る | すべて成功。NTSN なし |
| 段階 2 の後に 8 回問い合わせてから段階 3 | 手持ちが新鍵の cookie だけになり、段階 3 の後も成功 |
| 段階 1 の前に取得して以後問い合わせていない車両 | 段階 3 の後に NTSN を受け、API から 1 回取り直して成功 |

車両側には、外部から受け取った鍵と cookie で NTS の NTP を送るクライアントが要る。chrony の NTS クライアントは自分で NTS-KE を行う前提なので使えない。PoC では app/nts.py に AES-SIV と NTS の拡張フィールドを実装した。Debian bookworm の cryptography 38 は平文が空の AES-SIV 暗号化に失敗したため、AES-SIV は RFC 5297 のテストベクタで検算して自前で持っている。ECU 向けには C か Rust で同じものを書く。

NTS pool 拡張は ntpd-rs のドキュメントで beta とされ、draft も -01 で、IANA のコードポイント 8 から 14 は 2027-06-02 に期限を迎える仮登録になっている。ntpd-rs の更新で互換性が崩れる可能性がある。

ntpd-rs には chrony の -x に当たる動作がなく、時刻源を設定しなければ "No sources configured. Daemon will not change system time." と出してシステム時計をそのまま配る。システム時計の正しさは同じタスクの chrony -x が PHC と比べて監視し、ずれが閾値を超えたらヘルスチェックを落とす。ECS Managed Instances でタスクから /dev/ptp_ena が見えるか、ホストの ENA ドライバーで PHC が有効か、ホストの時計を何が同期しているかはドキュメントで確認できず、実機で確かめる。

車両を台帳から外しても、手持ちの cookie はマスター鍵が捨てられるまで使える。失効が効くまでの期間は、上のローテーションを回す間隔で決まる。

AWS 上での検証 (2026-10-22, ap-northeast-1, account 833707099141)

infra/ の Terraform で次を作った。車両役のクライアントは東京の Mac から動かした。

```
車両 ──mTLS──▶ api.ecu-time.riita.people.aws.dev (API Gateway HTTP API、execute-api 無効) ──▶ Lambda (VPC)
                                                    ──TCP 4460 + トークン──▶ 内部 NLB (Lambda の SG からのみ) ──▶ ntpd-rs
車両 ──UDP 123 NTS──▶ ntp.ecu-time.riita.people.aws.dev (公開 NLB、cross-zone) ──▶ ECS Managed Instances (m7g.large、2 AZ)
       タスク: ntpd-rs (NTS 必須) + chrony -x (169.254.169.123, time.aws.com, time.cloudflare.com NTS) + ヘルスチェック
       NAT Gateway は AZ ごと。cookie のマスター鍵は Secrets Manager に置き、全タスクが起動時に読む
```

鍵の共有方法は Secrets Manager にした。ntpd-rs は鍵ファイルを起動時にしか読まないので、DynamoDB に置いて要求ごとに引くには ntpd-rs の改造が要る。EFS で 1 つのファイルを共有すると、ntpd-rs がローテーションの周期ごとにファイルを truncate して書き直すため、別のタスクが起動時に書きかけのファイルを読み、乱数の新しい鍵で動き出すおそれがある。Secrets Manager なら版の管理と KMS による暗号化があり、ECS の secrets でタスク起動時に注入できる。ローテーションは scripts/aws-rotate-keyset.sh で新しい版を入れてローリングデプロイする。

| 検証 | 結果 |
|---|---|
| 証明書なしで API | TLS で切断 |
| 台帳にない VIN999 | 403 |
| execute-api の既定エンドポイント | 無効 (DisableExecuteApiEndpoint = True) |
| 平文 NTP を公開 NLB へ | kiss code DENY |
| 公開 NLB の TCP 4460 | 到達不可 |
| でたらめな cookie | NTSN |
| VIN001 で取得して NTS 付き NTP を 60 回 (毎回別ソケット) | 60/60 成功 |
| 精度 (遅延最小のサンプル) | 自前サーバー offset +0.856 ms delay 8.7 ms、time.aws.com offset +0.616 ms delay 14.2 ms。差 0.24 ms |
| タスクのシステム時計 (chrony -x の測定) | 169.254.169.123 (stratum 1、誤差範囲 ±73〜108 µs) に対して ±20 µs 程度 |
| PHC | ホストに /dev/ptp0 がなく、デバイスを渡すとタスクが起動しなかった。enable_phc = false で運用 |
| 鍵ローテーション 4 回 (prune、add、promote、prune) を 5 回/秒の問い合わせ中に実施 | 6950 回中 NTSN 0。失敗は UDP のタイムアウト 11 回 (0.16%)。ローテーションの外でも同程度出ている |
| NAT Gateway 障害 (AZ-a のデフォルトルートを削除) | 約 20 秒で AZ-a のタスクが unhealthy、NLB は AZ-c にだけ送り、車両側の失敗はタイムアウト 1 回。ルート復旧から約 20 秒で healthy に戻った |

わかったこと

ECS Managed Instances のタスクから 169.254.169.123 に届き、stratum 1 として見えた。強化版の Amazon Time Sync Service に相当する精度で、PHC がなくても車両側から見た誤差 (往復 8.7 ms の半分が上限) に比べて十分小さい。

ヘルスチェックが NAT Gateway の障害で落ちると、ECS は unhealthy としてタスクを置き換える (Amazon ECS replaced 1 tasks due to an unhealthy status)。置き換え先も同じ AZ なら同じく落ちるので、障害が長引くとタスクの入れ替えが繰り返される。NLB の振り分けは正しく AZ-c に寄るので時刻の配信は止まらないが、入れ替えを避けたいなら NAT の到達性をヘルスチェックから外して CloudWatch のアラームに回す方法がある。

UDP の応答が失われると、その応答で補充されるはずの cookie も失われる。PoC のクライアントは 1 回に 1 個しか補充を頼まないので、タイムアウト 8 回で手持ちの 8 個が尽き、API から 1 回取り直した。本番のクライアントは、手持ちが減ったら cookie placeholder を足して複数個の補充を頼む。

ローテーション 1 段階は 3〜5 分 (ローリングデプロイ)。

再現手順

```bash
terraform -chdir=infra init
terraform -chdir=infra apply -target=aws_ecr_repository.app
./scripts/aws-push-image.sh v1
terraform -chdir=infra apply
./scripts/aws-vehicle.sh check                     # Finch コンテナで実行
POC_DIR=$PWD uv run --with cryptography python app/aws_vehicle.py loop 600 0.2
./scripts/aws-rotate-keyset.sh add|promote|prune
./scripts/aws-nat-failure.sh ap-northeast-1a 90
terraform -chdir=infra destroy
```

結果ファイル: results-aws-check.txt、results-aws-rotation.txt、results-aws-loop.txt、results-aws-nat.txt
