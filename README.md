# BoxOpener (v0.3.8)

English follows the Japanese section. → [English](#english)

**FFXI (Windower 4) 用 箱の自動開封・NPC 交易アドオン**

大箱【ボウルダー】のような箱を、マクロで何百回も押さなくてよくするためのアドオンです。選んだ箱を、数を決めて（または無くなるまで）自動で開けます。かばんに無ければ、サッチェル・サック・ケース・金庫などから持ってきます。開けたアイテムは、ターゲットした NPC へ 8 枠ずつ、無くなるまで（または数を決めて）渡せます。

> **自己責任でお使いください。** 繰り返しの自動操作です。ゲームの利用規約に触れる可能性があり、運営側の検知の有無は分かりません。作者は結果について責任を負いません。アカウントの停止などの不利益を受ける可能性もあります。交易はパケットを直接送り、交易後の台詞を閉じるために決定キー（Enter）の入力を送ります。キャラクターの移動・NPC への接近はしません。選択肢のある会話は自分で操作してください（`//bo confirm off`）。

## 止まる条件
動くのは `//bo start` / `//bo give` を打ったときだけです。次のどれかで止まります。
- 指定した回数・数に達した、開けるアイテム・渡すアイテムが無くなった
- かばんの空きが「残す枠」(初期値 3) より少なくなった
- 開けても（渡しても）かばんの数が減らない（開封は 2 回続けて、交易は 8 秒）、他のバッグからの移動が確認できない（6 秒）
- 交易のあとのイベントが終わらない（30 秒、または決定キーを 8 回押しても）
- 戦闘中・イベント中など、状態が通常でなくなった
- ゾーンを移動した、NPC が遠い（6 歩より遠い）・いなくなった
- `//bo stop`、または Ctrl+Esc

## コマンド (`//bo` または `//boxopener`)
| コマンド | 説明 |
| :--- | :--- |
| `//bo add <アイテム名>` | 開ける箱を足す。複数選べる（大箱と小箱など）。名前は直接入力か、Tab のオートトランスレートで選ぶ |
| `//bo remove <アイテム名>` / `//bo clear` / `//bo list` | 外す / 全部外す / 一覧（かばんと他のバッグの数つき） |
| `//bo start [回数]` | 選んだ箱を順に開ける。回数を省くと無くなるまで |
| `//bo give <数\|all> <アイテム名> [@NPC名]` | かばんのアイテム（足りない分はサッチェルなど他のバッグから持ってくる）を、ターゲットした NPC（または名前を指定した NPC）へ 8 枠ずつ交易 |
| `//bo sort [on\|off\|<回ごと>]` | かばんの整頓（同じアイテムをまとめる）。何も付けないと今すぐ整頓。実行中は自動で整頓（初期値 10 回ごと・空きが少ないとき） |
| `//bo confirm on\|off` | 交易のあとの NPC の台詞を、決定キー（Enter）で閉じる（初期値 on）。選択肢のある会話では off にして手で閉じる |
| `//bo stop` | 中断（Ctrl+Esc でも可） |
| `//bo reserve <枠>` / `interval <秒>` / `key on\|off` / `lang auto\|ja\|en` / `status` | 設定と状態 |

例:
```
//bo add 大箱【ボウルダー】
//bo add 小箱【ボウルダー】
//bo start 400
//bo give all 宝箱【ボウルダー】
```

## 注意
- 渡す相手は NPC だけです。間違えてプレイヤーをターゲットしても、交易は申し込みません（モンスター・フェイス・ペットも同じ）。始めるときに相手の名前がチャットに出るので、確かめてください。
- ほかのバッグから持ってくるのは、そのとき開いているバッグだけです（サッチェル・サック・ケースは出先でも可。金庫・収納家具・ロッカーはモグハウスなど）。探す順は サッチェル → サック → ケース → 金庫 → 収納家具 → ロッカー → 金庫2 です。ワードローブは使いません。
- 交易のあとの NPC の台詞（Enter で閉じるもの）は、決定キーを押して閉じてから次の交易に進みます（1 ラウンドに最大 8 回）。選択肢のある会話では、最初の項目が選ばれてしまうので `//bo confirm off` にしてください。閉じても終わらないときは止まります。
- 中断キー（Ctrl+Esc）は実行中だけ割り当てます。使いたくないときは `//bo key off`。
- 表示はクライアントの言語に自動で合わせます。`//bo lang` を変えたあとは `//lua r BoxOpener` で読み込み直してください。
- 選んだアイテムの種類は確かめません。箱以外（装備や消耗品）を選ぶと、それも `/item` で使い続けます。回数を決めて使ってください。
- 決定キーの名前・押す回数・整頓の間隔・待つ秒数は `data/settings.xml` の `confirm_key`・`confirm_max`・`sort_every`・`use_timeout` で変えられます。
- ゲーム内で確かめていないこと: 9 枠を超える連続交易（2 ラウンド以上）を最後まで通すこと、20 回以上の実行での途中の整頓、英語クライアントでの動作。うまく動かないときは `//bo stop` で止めて報告してください。
- ゲームの設定でオートソートを切っていると、開けた中身が端数のまま溜まります。そのため実行中は自動で整頓します（`//bo sort off` で切れます）。

## インストール
`BoxOpener` フォルダーを `Windower4/addons/` に置き、`//lua load BoxOpener`。

## 更新履歴
- v0.3.8: 中断キーの割り当ての外し残しを修正・決定キーはイベント中だけ押す・アンロード/ログアウトの片付け・小数の回数は切り捨て・README の補足
- v0.3.7: 終わるときにも、かばんを最後に 1 回整頓する（回数が少ない実行でも端数がまとまる）
- v0.3.6: 数・回数を決めたときは、他のバッグから必要な分だけ持ってくる（枠ごとではない）
- v0.3.5: 数のあとに「|」などの区切りが付いても読める（`101|餅鉄`）。読めないときは受け取った文字のバイトも表示
- v0.3.4: 全角の空白・全角の数字で打っても読める（日本語入力のまま「101　餅鉄」と打つと数が読めなかった）。読めない入力は、そのまま表示
- v0.3.3: 交易でも、かばんに足りない分はサッチェルなど他のバッグから持ってくる
- v0.3.2: 台詞が閉じてターゲットが外れても、始めたときの NPC に交易を続ける（ターゲットを替えても相手は変わらない）
- v0.3.1: 渡す相手は NPC だけ（プレイヤー・モンスター・フェイス・ペットは対象外）。始めるときに相手の名前を表示
- v0.3.0: 交易のあとの決定キー（ゲーム内未確認）
- v0.2.0: 自動の整頓、開ける間隔の初期値を 3 秒に
- v0.1.0: 初版

---

## English

**Auto box opener and NPC trader for FFXI (Windower 4)**

Saves you from pressing a macro hundreds of times to open boxes such as the Boulder Box. Select the boxes and it opens them for the count you set, or until none are left. If your inventory has none, it brings them in from your Satchel, Sack, Case, Safe and so on. The opened items can then be traded to the NPC you target, 8 stacks at a time, until none are left or up to an amount you set.

> **Use at your own risk.** This is repeated automatic input. It may go against the game's terms of service, and whether the operator can detect it is unknown. The author takes no responsibility for the outcome, including account penalties. Trades are sent as packets, and after a trade it sends Enter key presses to close the NPC's message. It never moves your character or walks to an NPC. Handle conversations with menus yourself (`//bo confirm off`).

### It stops when
It only runs after you type `//bo start` or `//bo give`. It stops on any of these:
- the requested count/amount is reached, or no more items to open/give
- free inventory slots drop below the reserve (default 3)
- the item count does not drop after using/trading (opening: twice in a row; trading: 8 seconds), or a move into the inventory is not confirmed (6 seconds)
- the event after a trade does not end (30 seconds, or after 8 confirm key presses)
- you are not in a normal state (fighting, in an event, etc.), or you change zones
- the NPC is gone or farther than 6 yalms
- `//bo stop`, or Ctrl+Esc

### Commands (`//bo` or `//boxopener`)
| Command | Description |
| :--- | :--- |
| `//bo add <item name>` | Add a box to open. Several allowed. Type the name or pick it with Tab auto-translate |
| `//bo remove <item name>` / `//bo clear` / `//bo list` | Deselect / clear all / list (with counts in inventory and other bags) |
| `//bo start [count]` | Open the selected boxes in order; no count = until none are left |
| `//bo give <n\|all> <item name> [@NPC name]` | Trade items (brings in the rest from other bags) to your targeted NPC (or a named one), 8 stacks at a time |
| `//bo sort [on\|off\|<n>]` | Sort the inventory (stack like items). No argument = sort now. Sorts automatically while running (every 10 by default, and when free slots get low) |
| `//bo confirm on\|off` | Press the confirm key (Enter) to close the NPC message after a trade (default on). Turn off for conversations with menus |
| `//bo stop` | Stop (Ctrl+Esc also works) |
| `//bo reserve <slots>` / `interval <sec>` / `key on\|off` / `lang auto\|ja\|en` / `status` | Settings and status |

### Notes
- Only NPCs can be traded to. If you target a player by mistake, no trade request is sent (same for monsters, trusts and pets). The target's name is shown in chat when it starts, so check it.
- Only bags that are currently accessible are searched (Satchel, Sack and Case anywhere; Safe, Storage, Locker and Safe 2 only where the Mog House is available), in the order Satchel, Sack, Case, Safe, Storage, Locker, Safe 2. Wardrobes are not used.
- After a trade it presses the confirm key to close the NPC's message (up to 8 times per round), then goes on to the next trade. For conversations with a menu the first option would be chosen, so use `//bo confirm off`. It stops if the event does not end.
- Ctrl+Esc is bound only while running. `//bo key off` disables it.
- Display language follows the client language. After `//bo lang`, reload with `//lua r BoxOpener`.
- It does not check what kind of item you select. If you pick something that is not a box (gear, consumables), it keeps using that too. Set a count.
- The confirm key name, number of presses, sort interval and wait seconds can be changed in `data/settings.xml` (`confirm_key`, `confirm_max`, `sort_every`, `use_timeout`).
- Not verified in game: trading past 8 stacks (several rounds) all the way to the end, the mid-run sort in runs of 20+ openings, and behavior on the English client. If something goes wrong, stop with `//bo stop` and report it.
- If auto-sort is off in the game config, opened items pile up as partial stacks, so it sorts automatically while running (`//bo sort off` disables it).

### Install
Put the `BoxOpener` folder in `Windower4/addons/` and run `//lua load BoxOpener`.

### Changelog
- v0.3.8: fixes for a leftover Ctrl+Esc binding, the confirm key is pressed only during events, cleanup on unload/logout, fractional counts are rounded down, README additions
- v0.3.7: one last sort when a run ends, so short runs also get their partial stacks merged
- v0.3.6: with an amount/count set, only the needed quantity is brought in from other bags (not a whole stack)
- v0.3.5: a separator such as `|` after the amount is ignored (`101|item`); an unreadable amount is shown with its bytes
- v0.3.4: full-width spaces and digits are accepted; an unreadable amount is shown as typed
- v0.3.3: trades also bring in what the inventory lacks from other bags (Satchel etc.)
- v0.3.2: keeps trading to the NPC it started with even when the target is cleared after a message closes (changing your target does not change the recipient)
- v0.3.1: only NPCs can be traded to (never players, monsters, trusts or pets); the target's name is shown when starting
- v0.3.0: confirm key after trades (not yet tested in game)
- v0.2.0: auto sort; default opening interval is now 3 seconds
- v0.1.0: first version

License: MIT
