_addon.name = 'BoxOpener'
_addon.author = 'hikaruoshino'
_addon.version = '0.3.9'
_addon.commands = {'bo', 'boxopener'}

require('chat')
require('pack')
local config = require('config')
local res = require('resources')

-- 箱 (大箱【ボウルダー】など) を選んで自動で開け、開けたアイテムを NPC へトレードするアドオン。
-- 動くのは //bo start / //bo give を打ったときだけ。回数を決め、1 回ごとに「かばんの数が減った」ことを確かめてから次へ進む。
-- 失敗・かばんの空き不足・アイテム切れ・戦闘・ゾーン移動・状態が通常でない のどれかで止まる。//bo stop か Ctrl+Esc でも止まる。
-- キャラクターの移動・NPC への接近・会話の選択はしない。

-- 設定 (data/settings.xml)
--   items        : 開ける箱のアイテム ID (i6185,i6182 の形。数字だけだと設定ライブラリが数値と読んで型が合わなくなるため i を付ける。空は -)
--   reserve      : かばんに最低限残す空き (これを下回ると止まる)
--   interval     : 1 回開けてから次を開けるまでの秒数
--   use_timeout  : 開けたあと、かばんの数が減るのを待つ秒数 (これを過ぎると失敗)
--   key          : true なら、実行中だけ Ctrl+Esc を中断キーにする
--   autosort     : true なら、かばんの整頓 (同じアイテムをまとめる) を自動でする。ゲームの設定でオートソートを切っていると、開けた中身が端数のまま溜まるため
--   confirm      : true なら、トレードのあとの NPC の台詞 (イベント中) を、決定キーを押して閉じる。押すのはトレードのあとのイベント中だけで、1 ラウンドに confirm_max 回まで。
--                  選択肢のある会話では最初の項目が選ばれてしまうので、そういう NPC では //bo confirm off にして手で閉じる
--   confirm_key  : 決定キーの名前 (Windower の setkey のキー名)。通すのは enter だけ (ほかの名前は enter に戻す)
--   confirm_max  : 1 ラウンドに押す決定キーの回数の上限 (1〜8。8 を超える値は 8 に丸める)
--   sort_every   : 何回 (トレードは何ラウンド) ごとに整頓するか。空きが残す枠 + 2 より少ないときも整頓する
local defaults = {
    items = '-',
    reserve = 3,
    interval = 3.0,
    use_timeout = 8,
    key = true,
    autosort = true,
    confirm = true,
    confirm_key = 'enter',
    confirm_max = 8,
    sort_every = 10,
    lang = 'auto',          -- 表示の言語: auto (クライアントの言語に合わせる) / ja / en
}
local fallback = {}
for k, v in pairs(defaults) do fallback[k] = v end
local settings = config.load(defaults)

-- settings.xml を手で書き換えた値を、使える範囲へ丸める (数でなければ既定値)。
-- 設定ライブラリはログイン・ログアウトで読み直すので、config.register で読み直しのたびにも丸める
local function clamp_setting(key, lo, hi, int)
    local n = tonumber(settings[key])
    if n == nil or n ~= n then n = fallback[key] end
    if int then n = math.floor(n) end
    if n < lo then n = lo elseif n > hi then n = hi end
    settings[key] = n
end

-- 決定キーとして通すキーの名前 (setkey に渡す名前)。決定以外の働きをするキー (移動・カーソル・メニューを閉じるなど) は通さない。
-- ゲーム内で確かめたのは enter だけなので、enter だけを通す (大文字小文字は無視し、小文字にそろえる)
local CONFIRM_KEYS = { enter = true }
-- 1 ラウンドに押す決定キーの回数の上限。選択肢のある会話で、押し続けて項目を決めてしまわないよう、設定でもこれを超えない
local CONFIRM_MAX_CAP = 8

local function sanitize_settings()
    clamp_setting('reserve', 0, 80, true)
    clamp_setting('interval', 1, 30, false)
    clamp_setting('use_timeout', 2, 60, false)
    clamp_setting('confirm_max', 1, CONFIRM_MAX_CAP, true)
    clamp_setting('sort_every', 1, 100, true)
    -- 決定キーは setkey にそのまま渡すので、許可した名前だけを通す (ほかは既定の enter)
    local key = type(settings.confirm_key) == 'string' and settings.confirm_key:lower() or ''
    if CONFIRM_KEYS[key] then settings.confirm_key = key else settings.confirm_key = fallback.confirm_key end
end
sanitize_settings()
config.register(settings, sanitize_settings)

local function client_is_ja()
    local ok, info = pcall(windower.ffxi.get_info)
    local l = ok and info and info.language and tostring(info.language):lower() or 'japanese'
    return l == 'japanese'
end
local CLIENT_JA = client_is_ja()

local function resolve_lang()
    local s = tostring(settings.lang or 'auto'):lower()
    if s == 'ja' or s == 'en' then return s end
    return CLIENT_JA and 'ja' or 'en'
end
local LANG = resolve_lang()

local function L(ja, en)
    if LANG == 'ja' then return ja end
    return en
end

-- UTF-8 -> Shift-JIS (日本語表示のとき)。チャットとコマンドに出す文字列に通す
local function sjis(str)
    if not str then return '' end
    return windower.to_shift_jis and windower.to_shift_jis(str) or str
end

-- チャットから届く引数 (Shift-JIS・オートトランスレートの語を含む) を UTF-8 に戻す
local function from_sjis(str)
    if not str then return nil end
    local s = windower.convert_auto_trans and windower.convert_auto_trans(str) or str
    return windower.from_shift_jis and windower.from_shift_jis(s) or s
end

local function say(text, color)
    windower.add_to_chat(color or 207, sjis('[BoxOpener] ' .. text))
end

local function num(v, default)
    local n = tonumber(v)
    if n == nil then return default end
    return n
end

----------------------------------------------------------------------
-- アイテム名 <-> ID
----------------------------------------------------------------------

-- アイテムの表示名 (表示の言語に合わせる)
local function item_name(id)
    local row = res.items[id]
    if not row then return tostring(id) end
    if LANG == 'ja' then return row.ja or row.en or tostring(id) end
    return row.en or row.ja or tostring(id)
end

-- 使えるバッグ (かばんの外)。持ち運べるもの → モグハウスのもの の順に探す
local OTHER_BAGS = {5, 6, 7, 1, 2, 4, 9}

local function bag_enabled(bag)
    local info = windower.ffxi.get_bag_info(bag)
    return info and info.enabled
end

-- かばんと使えるバッグのどこかに、そのアイテムがあるか
local function owns(id)
    local function has(bag)
        for _, it in ipairs(windower.ffxi.get_items(bag) or {}) do
            if it.id == id and (it.count or 0) > 0 then return true end
        end
        return false
    end
    if has(0) then return true end
    for _, bag in ipairs(OTHER_BAGS) do
        if bag_enabled(bag) and has(bag) then return true end
    end
    return false
end

-- 名前から ID を探す。日本語名・英語名 (略称も) の完全一致。
-- 同じ名前のアイテムが複数あるときは、持っているものを選ぶ (持っていなければ ID の小さいもの)
local function find_item_exact(name)
    if not name or name == '' then return nil end
    local lower = name:lower()
    local found = {}
    for id, row in pairs(res.items) do
        if type(row) == 'table' and (row.ja == name or row.jal == name
            or (row.en and row.en:lower() == lower) or (row.enl and row.enl:lower() == lower)) then
            found[#found + 1] = id
        end
    end
    if #found <= 1 then return found[1] end
    table.sort(found)
    for _, id in ipairs(found) do
        if owns(id) then return id end
    end
    return found[1]
end

-- いま持っているアイテムの中から、名前の一部が合うものを探す (完全一致が無いとき用)
local function find_item_owned(name)
    local lower = name:lower()
    local found, n = nil, 0
    local seen = {}
    local function scan(bag)
        local items = windower.ffxi.get_items(bag)
        if not items then return end
        for _, it in ipairs(items) do
            local id = it.id
            if id and id > 0 and not seen[id] then
                seen[id] = true
                local row = res.items[id]
                if row and ((row.ja and row.ja:find(name, 1, true)) or (row.en and row.en:lower():find(lower, 1, true))) then
                    found, n = id, n + 1
                end
            end
        end
    end
    scan(0)
    for _, bag in ipairs(OTHER_BAGS) do
        if bag_enabled(bag) then scan(bag) end
    end
    if n == 1 then return found end
    return nil, n
end

-- 戻り値: ID, エラー文, 名前の一部で決めたなら true
local function resolve_item(name)
    local id = find_item_exact(name)
    if id then return id end
    local id2, n = find_item_owned(name)
    if id2 then return id2, nil, true end
    if n and n > 1 then
        return nil, L('名前が複数のアイテムに当てはまります: ', 'Several items match: ') .. name
    end
    return nil, L('アイテムが見つかりません: ', 'Unknown item: ') .. name
end

-- 選んだ ID の一覧。res に無い ID (設定の書き換え・アップデート前の res) は外し、2 つ目の戻り値で返す
local function selected_ids()
    local ids, dropped = {}, {}
    for part in tostring(settings.items or ''):gmatch('%d+') do
        local id = tonumber(part)
        if res.items[id] then ids[#ids + 1] = id else dropped[#dropped + 1] = id end
    end
    return ids, dropped
end

local function save_ids(ids)
    local parts = {}
    for _, id in ipairs(ids) do parts[#parts + 1] = 'i' .. tostring(id) end
    settings.items = #parts > 0 and table.concat(parts, ',') or '-'
    config.save(settings)
end

----------------------------------------------------------------------
-- かばんの数え方
----------------------------------------------------------------------

-- かばん (bag 0) の中身の表。読めないとき (ゾーン移動中など、表でない値が返ったとき) は nil。空の表 {} は「読めて 0 個」
local function inv_items()
    local items = windower.ffxi.get_items(0)
    if type(items) ~= 'table' then return nil end
    return items
end

-- かばん (bag 0) の、そのアイテムの合計数 (装備中は除く)。かばんを読めないときは nil (0 個とは区別する)
local function inv_count(id)
    local items = inv_items()
    if not items then return nil end
    local total = 0
    for _, it in ipairs(items) do
        if type(it) == 'table' and it.id == id and (it.status or 0) == 0 then total = total + (it.count or 1) end
    end
    return total
end

-- かばん以外のバッグで、そのアイテムが入っている最初の場所 {bag, slot, count}
local function find_elsewhere(id)
    for _, bag in ipairs(OTHER_BAGS) do
        if bag_enabled(bag) then
            local items = windower.ffxi.get_items(bag)
            if items then
                for _, it in ipairs(items) do
                    if it.id == id and (it.count or 0) > 0 then
                        return {bag = bag, slot = it.slot, count = it.count}
                    end
                end
            end
        end
    end
    return nil
end

local function elsewhere_total(id)
    local total = 0
    for _, bag in ipairs(OTHER_BAGS) do
        if bag_enabled(bag) then
            local items = windower.ffxi.get_items(bag)
            if items then
                for _, it in ipairs(items) do
                    if it.id == id then total = total + (it.count or 0) end
                end
            end
        end
    end
    return total
end

local function free_slots()
    local info = windower.ffxi.get_bag_info(0)
    if not info then return 0 end
    return num(info.max, 0) - num(info.count, 0)
end

local function player_status()
    local p = windower.ffxi.get_player()
    return p and p.status or nil
end

----------------------------------------------------------------------
-- 実行の本体 (状態機械)
----------------------------------------------------------------------

local job = nil          -- 実行中の仕事。nil なら何もしない (prerender は何もせず戻る)
local KEY = '^escape'

local key_bound = false

local function bind_key()
    if settings.key then
        windower.send_command('bind ' .. KEY .. ' bo stop')
        key_bound = true
    end
end

local function unbind_key()
    if key_bound then
        windower.send_command('unbind ' .. KEY)
        key_bound = false
    end
end

local last_sort = -100

-- 止めた時刻 (os.clock)。止めたあとも、送り済みの /item・トレードの結果 (かばんの数の減り) が遅れて届くことがある。
-- すぐ始め直すと、新しい実行がその減りを自分の分と数えるので、止めてから START_COOLDOWN 秒は始めない。nil は「まだ止めていない」
local START_COOLDOWN = 4.0
local last_stop = nil

-- 終わるとき (回数に達した・アイテムが無くなった・空きが足りない) に、かばんを最後に 1 回整頓する。
-- 途中の整頓は N 回ごとなので、回数が N に届かない実行 (//bo start 10 など) でも、開けた中身の端数がまとまる
local function finish(reason, color, sort)
    if not job then return end
    local j = job
    job = nil
    last_stop = os.clock()
    unbind_key()
    if sort and settings.autosort and j.done > 0 and os.clock() - last_sort >= 1 then
        windower.ffxi.stack_items(0)
        last_sort = os.clock()
    end
    if j.kind == 'open' then
        say(string.format(L('開封を終了しました (%d 回): %s', 'Stopped opening (%d done): %s'), j.done, reason), color or 167)
    else
        say(string.format(L('トレードを終了しました (%d 個): %s', 'Stopped trading (%d items): %s'), j.done, reason), color or 167)
    end
end

local function start_job(j)
    if job then
        say(L('すでに実行中です。止めるには //bo stop', 'Already running. //bo stop to stop it'), 123)
        return false
    end
    local now = os.clock()
    if last_stop then
        -- 時計が戻った (止めた時刻より今が前) ときは、待ちを解く (永遠に断らない)
        if now < last_stop then last_stop = nil
        elseif now - last_stop < START_COOLDOWN then
            say(string.format(L('直前の操作の結果が届くまで少し待ってください (あと %.1f 秒)', 'Wait a moment for the result of the last action (%.1f s left)'),
                START_COOLDOWN - (now - last_stop)), 123)
            return false
        end
    end
    job = j
    j.next_at = now + (j.delay or 0)
    bind_key()
    return true
end

-- 決定キーを 1 回押す (setkey の down → up)。キーの名前は設定の confirm_key
local function press_confirm()
    local key = tostring(settings.confirm_key or 'enter')
    windower.send_command('setkey ' .. key .. ' down')
    coroutine.schedule(function() windower.send_command('setkey ' .. key .. ' up') end, 0.15)
end

-- かばんの整頓 (windower.ffxi.stack_items。itemizer と同じ呼び方)。ゲームのメニューの「整頓」と同じ
-- 整頓は枠の並びを変える。トレードのパケット (0x36) は枠の番号と数だけを送るので、並びが変わる前の番号で組むと別のアイテムを渡しうる。
-- 整頓の完了を知らせる受信パケットは確かめられていないため、整頓から SORT_WAIT 秒たつまでトレードを組まない
local SORT_WAIT = 3.0     -- 整頓の結果がかばんに反映されるのを待つ秒数
local SORT_GAP = 5.0      -- 整頓の最短の間隔
local GIVE_GRACE = 3      -- give で名前の一部からアイテムを決めたとき、最初のトレードまで待つ秒数
local function do_sort(now)
    windower.ffxi.stack_items(0)
    last_sort = now
end

-- 整頓するべきなら整頓して true (呼んだ側は state を wait_sort にして待つ)
-- 空きが少ないための整頓で空きが変わらなかったら、空きが変わるまで、その理由では整頓し直さない
local function maybe_sort(j, now)
    if not settings.autosort then return false end
    if now - last_sort < SORT_GAP then return false end
    local every = math.max(1, math.floor(num(settings.sort_every, 10)))
    local free = free_slots()
    local low = free < num(settings.reserve, 3) + 2 and free ~= j.sort_stuck_free
    if j.since_sort >= every or low then
        j.since_sort = 0
        j.sort_free_before = free
        do_sort(now)
        j.sort_until = now + SORT_WAIT
        j.state = 'wait_sort'
        return true
    end
    return false
end

-- 整頓の待ちが終わったときに呼ぶ。空きが変わらなかったら、その空きを覚えておく
local function end_sort_wait(j)
    local free = free_slots()
    if free == j.sort_free_before then j.sort_stuck_free = free else j.sort_stuck_free = nil end
    j.state = 'pick'
end

-- 状態が通常 (0) でないときは動かさない (戦闘中・イベント中・倒れている等)
local function status_ok()
    local s = player_status()
    return s == 0
end

-- 次の 1 回を選ぶとき (pick) に、かばんを読めなかった。無くなったとは数えず、状態も数も変えずに次の tick で読み直す。
-- pick には期限が無いので、読めない状態が use_timeout 秒続いたら止める (時計が戻ったら数え直す)
local function hold_unreadable(j, now)
    if not j.unread_since or now < j.unread_since then j.unread_since = now end
    if now - j.unread_since > num(settings.use_timeout, 8) then
        return finish(L('かばんを読めません (ゾーン移動中など)', 'Cannot read the inventory (zoning, etc.)'), 123)
    end
end

----- 開封 -----

local function open_step(now)
    local j = job

    if j.state == 'wait_sort' then
        if now >= j.sort_until then end_sort_wait(j) end
        return
    end

    if j.state == 'wait_move' then
        -- かばんを読めない (nil) ときは判定を保留する。期限は進む
        local c = inv_count(j.cur)
        if c and c > j.before then
            j.state = 'pick'
            j.next_at = now + 0.5
            return
        end
        if now > j.deadline then return finish(L('かばんへの移動が確認できませんでした', 'The move into the inventory was not confirmed'), 123) end
        return
    end

    if j.state == 'wait_use' then
        -- かばんを読めない (nil) ときは「使った」と数えず保留する。期限は進むので、読めないままなら下の時間切れの扱いになる
        local c = inv_count(j.cur)
        if c and c < j.before then
            -- 時間切れのあとに遅れて減った分も含めて、減った数を全部数える
            local used = j.before - c
            j.done = j.done + used
            j.since_sort = j.since_sort + used
            j.fails = 0
            j.carry_id = nil
            j.state = 'pick'
            j.next_at = now + num(settings.interval, 3.0)
            return
        end
        if now > j.deadline then
            j.fails = j.fails + 1
            if j.fails >= 2 then
                return finish(L('開けても数が減りません (2 回続けて)。他の行動中・かばんの空き不足・使えない場所の可能性があります', 'The count does not drop after using (twice in a row): busy, no room, or cannot use here'), 123)
            end
            -- 時間切れの時点の数を覚えておく。あとで遅れて減ったら、次の判定でその分も数える。
            -- 送り済みの /item は、遅れて効くことがある。減るまで (carry_id が残る間) は次の /item を送らずに待ち、
            -- carry_until を過ぎても減らなければ 2 回目の失敗として止める
            j.carry_id = j.cur
            j.carry_before = j.before
            j.carry_from = now
            j.carry_until = now + num(settings.use_timeout, 8)
            j.state = 'pick'
            j.next_at = now + num(settings.interval, 3.0)
        end
        return
    end

    -- state == 'pick': 次の 1 回を始める前の確認
    -- かばんを読めないときは、何も判定せずに次の tick で読み直す (無くなった・使ったとは数えない)
    if not inv_items() then return hold_unreadable(j, now) end
    j.unread_since = nil
    if j.carry_id then
        local c = inv_count(j.carry_id)
        if not c then return hold_unreadable(j, now) end
        if c < j.carry_before then
            local used = j.carry_before - c
            j.done = j.done + used
            j.since_sort = j.since_sort + used
            j.fails = 0
            j.carry_id = nil
        else
            -- 時間切れの 1 回がまだ減っていない。/item を重ねて送らず、待つ (時計が戻ったら待ちを数え直す)
            if not j.carry_from or now < j.carry_from then
                j.carry_from = now
                j.carry_until = now + num(settings.use_timeout, 8)
            end
            if now <= (j.carry_until or now) then return end
            return finish(L('開けても数が減りません (2 回続けて)。他の行動中・かばんの空き不足・使えない場所の可能性があります', 'The count does not drop after using (twice in a row): busy, no room, or cannot use here'), 123)
        end
    end
    if j.limit and j.done >= j.limit then
        return finish(L('指定した回数に達しました', 'Reached the requested count'), 207, true)
    end
    if not status_ok() then
        return finish(L('状態が通常ではありません (戦闘中・イベント中など)', 'Not in a normal state (fighting, in an event, etc.)'), 123)
    end
    if maybe_sort(j, now) then return end
    if free_slots() < num(settings.reserve, 3) then
        return finish(L('かばんの空きが足りません', 'Not enough free inventory slots'), 123, true)
    end

    -- 選んだアイテムのうち、まだ残っている最初のもの
    local cur, here
    for _, id in ipairs(j.ids) do
        local c = inv_count(id)
        if not c then return hold_unreadable(j, now) end
        if c > 0 or elsewhere_total(id) > 0 then cur, here = id, c break end
    end
    if not cur then
        return finish(L('開けるアイテムが無くなりました', 'No more items to open'), 207, true)
    end
    j.cur = cur

    if here == 0 then
        -- かばんに無いので、ほかのバッグから 1 枠ぶん持ってくる
        local at = find_elsewhere(cur)
        if not at then
            return finish(L('開けるアイテムが無くなりました', 'No more items to open'), 207, true)
        end
        if free_slots() < num(settings.reserve, 3) + 1 then
            return finish(L('かばんの空きが足りません', 'Not enough free inventory slots'), 123, true)
        end
        j.before = here
        j.carry_id = nil
        -- 回数を決めているときは、残りの回数ぶんだけ持ってくる (余りをかばんに持ち込まない)
        local take = j.limit and math.max(1, math.min(at.count, j.limit - j.done)) or at.count
        windower.ffxi.move_item(at.bag, 0, at.slot, take)
        j.state = 'wait_move'
        j.deadline = now + 6
        return
    end

    local row = res.items[cur]
    if not row then
        return finish(L('res に無いアイテムです: ', 'Not in the resources: ') .. tostring(cur), 123)
    end
    -- 時間切れのあとで、まだ減っていない 1 回があるなら、その時点の数から数える (遅れて減った分も数えるため)
    if j.carry_id == cur then j.before = j.carry_before else j.before = here end
    j.carry_id = nil
    local name = (CLIENT_JA and (row.ja or row.en)) or row.en or row.ja
    windower.chat.input(sjis('/item "' .. name .. '" <me>'))
    j.state = 'wait_use'
    j.deadline = now + num(settings.use_timeout, 8)
end

----- トレード -----

-- トレードする相手として良いのは、6 歩以内の NPC だけ。プレイヤー・モンスター・フェイス・ペットは対象外
-- (TradeNPC と同じ判定: is_npc かつ spawn_type が 0x20 のビットを除いて 2 = NPC)。間違えてプレイヤーをターゲットしても、トレードを申し込まない
local function npc_ok(npc)
    if not (npc and npc.is_npc and npc.valid_target) then return false end
    local st = tonumber(npc.spawn_type) or 0
    if st - (math.floor(st / 32) % 2) * 32 ~= 2 then return false end
    return math.sqrt(npc.distance or 9999) < 6
end

local function find_npc_by_name(name)
    for _, npc in pairs(windower.ffxi.get_mob_array()) do
        if npc and npc.name and npc.name:lower() == name:lower() and npc_ok(npc) then return npc end
    end
    return nil
end

local function current_npc(j)
    if j.npc_name then return find_npc_by_name(j.npc_name) end
    -- 台詞が閉じるとターゲットが外れるので、始めたときに控えた ID で探す (ターゲットを替えても、相手は最初の NPC のまま)
    local m = windower.ffxi.get_mob_by_id(j.npc_id)
    if npc_ok(m) then return m end
    return nil
end

-- かばんの、そのアイテムが入っている枠の数。かばんを読めないときは nil
local function inv_stacks(id)
    local items = inv_items()
    if not items then return nil end
    local n = 0
    for _, it in ipairs(items) do
        if type(it) == 'table' and it.id == id and (it.status or 0) == 0 and (it.count or 0) > 0 then n = n + 1 end
    end
    return n
end

-- かばんの、そのアイテムの枠 (装備中は除く) を順に集めて、最大 8 枠ぶんのトレードを組み立てる。かばんを読めないときは nil
local function build_trade(id, want)
    local items = inv_items()
    if not items then return nil end
    local ind, qty = {}, {}
    local left = want
    for k, it in ipairs(items) do
        if #ind >= 8 or left <= 0 then break end
        if type(it) == 'table' and it.id == id and (it.status or 0) == 0 and (it.count or 0) > 0 then
            local q = math.min(it.count, left)
            ind[#ind + 1] = k
            qty[#qty + 1] = q
            left = left - q
        end
    end
    return ind, qty
end

local function send_trade(npc, ind, qty)
    local n = #ind
    local i, q = {}, {}
    for x = 1, 9 do
        i[x] = ind[x] or 0
        q[x] = qty[x] or 0
    end
    local packet = ('C4I11C10HI'):pack(0x36, 0x20, 0x00, 0x00, npc.id,
        q[1], q[2], q[3], q[4], q[5], q[6], q[7], q[8], q[9], 0x00,
        i[1], i[2], i[3], i[4], i[5], i[6], i[7], i[8], i[9], 0x00,
        npc.index, n)
    windower.packets.inject_outgoing(0x36, packet)
end

local function give_step(now)
    local j = job

    if j.state == 'wait_sort' then
        if now >= j.sort_until then end_sort_wait(j) end
        return
    end

    if j.state == 'wait_move' then
        -- かばんを読めない (nil) ときは判定を保留する。期限は進む
        local c = inv_count(j.id)
        if c and c > j.before then
            j.state = 'pick'
            j.next_at = now + 0.5
            return
        end
        if now > j.deadline then return finish(L('かばんへの移動が確認できませんでした', 'The move into the inventory was not confirmed'), 123) end
        return
    end

    if j.state == 'wait_trade' then
        -- かばんを読めない (nil) ときは「渡した」と数えず保留する。期限は進むので、読めないままなら下の時間切れで止まる
        local c = inv_count(j.id)
        if c and c <= j.before - j.expect then
            j.done = j.done + j.expect
            j.since_sort = j.since_sort + 1
            j.state = 'wait_event'
            j.idle_since = nil
            j.presses = 0
            j.last_press = now
            j.event_from = now
            j.deadline = now + 30
            return
        end
        if now > j.deadline then
            return finish(L('トレードが成立しませんでした (NPC が受け取らない・遠い・他の行動中)', 'The trade did not go through (NPC did not accept, too far, or busy)'), 123)
        end
        return
    end

    if j.state == 'wait_event' then
        -- トレードのあとのイベントが終わる (状態が通常に戻る) まで待つ。イベントが始まる前に通り過ぎないよう、通常が 1.5 秒続いてから次へ進む
        if status_ok() then
            j.idle_since = j.idle_since or now
            if now - j.idle_since >= 1.5 and now - j.event_from >= 1.5 then
                j.state = 'pick'
                j.next_at = now + 0.5
            end
        else
            j.idle_since = nil
            -- 押すのはイベント中 (状態 4) だけ。戦闘など、ほかの状態になっていたら押さず、期限で止まる
            if settings.confirm and player_status() == 4 and now - j.last_press >= 1.5 then
                if j.presses >= math.min(CONFIRM_MAX_CAP, math.max(1, math.floor(num(settings.confirm_max, CONFIRM_MAX_CAP)))) then
                    return finish(L('決定キーを押してもイベントが終わりません。選択肢のある会話かもしれません。手で閉じてください', 'The event does not end after pressing the confirm key; it may have a menu. Close it by hand'), 123)
                end
                j.presses = j.presses + 1
                j.last_press = now
                press_confirm()
            elseif now > j.deadline then
                return finish(L('トレードのあとのイベントが終わりません。会話の選択が必要かもしれません', 'The event after the trade did not end; a menu choice may be needed'), 123)
            end
        end
        return
    end

    -- state == 'pick'
    -- かばんを読めないときは、何も判定せずに次の tick で読み直す (無くなったとは数えない)
    local have = inv_count(j.id)
    if not have then return hold_unreadable(j, now) end
    j.unread_since = nil
    if j.limit and j.done >= j.limit then
        return finish(L('指定した数に達しました', 'Reached the requested amount'), 207, true)
    end
    if not status_ok() then
        return finish(L('状態が通常ではありません', 'Not in a normal state'), 123)
    end
    if maybe_sort(j, now) then return end
    -- かばんの分が 1 回 (8 枠) ぶんに足りないなら、ほかのバッグから 1 枠ぶん持ってくる
    local need = j.limit and (j.limit - j.done) or math.huge
    local stacks = inv_stacks(j.id)
    if not stacks then return hold_unreadable(j, now) end
    if stacks < 8 and have < need and free_slots() >= num(settings.reserve, 3) + 1 then
        local at = find_elsewhere(j.id)
        if at then
            j.before = have
            -- 数を決めているときは、足りない分だけ持ってくる (余りをかばんに持ち込まない)
            local take = j.limit and math.max(1, math.min(at.count, need - have)) or at.count
            windower.ffxi.move_item(at.bag, 0, at.slot, take)
            j.state = 'wait_move'
            j.deadline = now + 6
            return
        end
    end
    if have == 0 then
        return finish(L('トレードするアイテムが無くなりました', 'No more items to give'), 207, true)
    end
    if free_slots() < num(settings.reserve, 3) then
        return finish(L('かばんの空きが足りません', 'Not enough free inventory slots'), 123, true)
    end
    local npc = current_npc(j)
    if not npc then
        return finish(L('相手の NPC が見つからないか、遠すぎます (6 歩以内)', 'The NPC is gone or too far (within 6 yalms)'), 123)
    end
    -- 整頓 (自動・手動・終わるときの整頓) から SORT_WAIT 秒たつまでは、枠の番号を組まない
    if now - last_sort < SORT_WAIT then
        j.next_at = last_sort + SORT_WAIT
        return
    end
    local want = j.limit and math.min(j.limit - j.done, have) or have
    local ind, qty = build_trade(j.id, want)
    if not ind then return hold_unreadable(j, now) end
    if #ind == 0 then
        return finish(L('トレードするアイテムが無くなりました', 'No more items to give'), 207, true)
    end
    local total = 0
    for _, q in ipairs(qty) do total = total + q end
    j.before = have
    j.expect = total
    send_trade(npc, ind, qty)
    j.state = 'wait_trade'
    j.deadline = now + 8
end

local function step(now)
    if job.kind == 'open' then open_step(now) else give_step(now) end
end

windower.register_event('prerender', function()
    if not job then return end
    local now = os.clock()
    if now < job.next_at then return end
    -- 思わぬエラーで毎フレーム同じエラーを出し続けないよう、エラーが出たら片付けて止める
    local ok, err = pcall(step, now)
    if not ok then
        if job then finish(L('エラーのため止めました: ', 'Stopped by an error: ') .. tostring(err), 123) end
        return
    end
    if job then job.next_at = math.max(job.next_at, now + 0.25) end
end)

windower.register_event('zone change', function()
    if job then finish(L('ゾーンを移動しました', 'Changed zones'), 167) end
end)

local function release_confirm_key()
    windower.send_command('setkey ' .. tostring(settings.confirm_key or 'enter') .. ' up')
end

windower.register_event('unload', function()
    -- 実行中でなくても、押したままの決定キーが残らないよう離す (終わった直後のアンロードで up がまだ届いていない場合など)
    job = nil
    release_confirm_key()
    unbind_key()
end)

windower.register_event('logout', function()
    if job then finish(L('ログアウトしました', 'Logged out'), 167) end
end)

----------------------------------------------------------------------
-- コマンド
----------------------------------------------------------------------

local function show_list()
    local ids = selected_ids()
    if #ids == 0 then
        say(L('開ける箱が選ばれていません。//bo add <アイテム名>', 'No boxes selected. //bo add <item name>'))
        return
    end
    for i, id in ipairs(ids) do
        -- かばんを読めないときは ? と出す
        local here, there = inv_count(id), elsewhere_total(id)
        say(string.format(L('%d. %s  (かばん %s / ほかのバッグ %d)', '%d. %s  (inventory %s / other bags %d)'), i, item_name(id), here and tostring(here) or '?', there))
    end
end

local function show_help()
    say(L('//bo add <名前>        開ける箱を足す (Tab のオートトランスレートも可。複数選べる)', '//bo add <name>        add a box to open (Tab auto-translate works; several allowed)'))
    say(L('//bo remove <名前>     選びから外す / //bo clear 全部外す / //bo list 一覧', '//bo remove <name>     deselect / //bo clear all / //bo list'))
    say(L('//bo start [回数]      選んだ箱を開ける (回数を省くと、無くなるまで)', '//bo start [count]     open the selected boxes (no count = until none left)'))
    say(L('//bo give <数|all> <名前> [@NPC名]  選んだ NPC (ターゲット) へ 8 枠ずつトレード', '//bo give <n|all> <name> [@NPC]  trade to the targeted NPC, 8 stacks at a time'))
    say(L('//bo stop             中断 (Ctrl+Esc でも止まる)', '//bo stop             stop (Ctrl+Esc also stops)'))
    say(L('//bo sort [on|off|<回ごと>]  かばんの整頓 (何も付けないと今すぐ整頓。実行中は自動)', '//bo sort [on|off|<n>]  sort the inventory (no argument = sort now; automatic while running)'))
    say(L('//bo confirm on|off  トレードのあとの NPC の台詞を決定キーで閉じる (選択肢のある会話では off)', '//bo confirm on|off  close the NPC message after a trade with the confirm key (turn off for menus)'))
    say(L('//bo reserve <枠> / interval <秒> / key on|off / lang auto|ja|en / status', '//bo reserve <slots> / interval <sec> / key on|off / lang auto|ja|en / status'))
end

-- 引数を「名前」にまとめる (Shift-JIS → UTF-8・オートトランスレート変換のあと、空白でつなぐ)
local function join_name(args, from, to)
    local parts = {}
    for i = from, to or #args do parts[#parts + 1] = from_sjis(args[i]) end
    return (table.concat(parts, ' '):gsub('^%s+', ''))
end

local FW_SPACE = '\227\128\128'

-- 先頭の「数」の部分だけ、全角の数字 (U+FF10〜FF19) を ASCII の数字に、数のすぐあとの全角の空白 (U+3000) を ASCII の空白に直す。
-- 日本語入力のまま「101　餅鉄」と打つと、空白で区切られず 1 つの語として届くため。
-- 名前の中の全角の文字 (「３号ガーランド」「みんなの美術　初級」) は直さない
local function normalize_amount(str)
    local i, digits = 1, {}
    while true do
        local b1, b2, b3 = str:byte(i, i + 2)
        if b1 == 239 and b2 == 188 and b3 and b3 >= 144 and b3 <= 153 then
            digits[#digits + 1] = string.char(b3 - 96)
            i = i + 3
        else
            break
        end
    end
    str = table.concat(digits) .. str:sub(i)
    local amount, rest = str:match('^(%d+)(.*)$')
    if not amount then amount, rest = str:match('^([Aa][Ll][Ll])(.*)$') end
    if not amount then return str end
    local sep = 0
    while true do
        if rest:sub(sep + 1, sep + 1):find('^[%s|]') then
            sep = sep + 1
        elseif rest:sub(sep + 1, sep + 3) == FW_SPACE then
            sep = sep + 3
        else
            break
        end
    end
    return amount .. (rest:sub(1, sep):gsub(FW_SPACE, ' ')) .. rest:sub(sep + 1)
end

-- 先頭の「数」または all と、そのあとの名前に分ける。数・all のあとには区切り (空白・|・文字列の終わり) が要る
-- (「Alloy Tonic」を all + 「oy Tonic」と読まないため)
local function split_amount(str)
    local amount, rest = str:match('^(%d+)(.*)$')
    if not amount then amount, rest = str:match('^([Aa][Ll][Ll])(.*)$') end
    if not amount then return nil end
    if rest ~= '' and not rest:find('^[%s|]') then return nil end
    return amount:lower(), (rest:gsub('^[%s|]+', ''))
end

-- 設定はログイン中だけ保存できる (設定ライブラリはログイン前の保存を捨てる)
local function can_save()
    local info = windower.ffxi.get_info()
    if info and info.logged_in then return true end
    say(L('ログインしてから設定してください (ログイン前は保存されません)', 'Log in first; settings cannot be saved before login'), 123)
    return false
end

local SAVE_COMMANDS = {add = true, remove = true, rm = true, clear = true, reserve = true, interval = true,
    confirm = true, key = true, lang = true}

windower.register_event('addon command', function(cmd, ...)
    local args = {...}
    cmd = cmd and cmd:lower() or 'help'

    if SAVE_COMMANDS[cmd] and not can_save() then return end
    if cmd == 'sort' and args[1] and not can_save() then return end

    if cmd == 'add' then
        local name = join_name(args, 1)
        if name == '' then say(L('//bo add <アイテム名>', '//bo add <item name>'), 123) return end
        local id, err = resolve_item(name)
        if not id then say(err, 123) return end
        local ids = selected_ids()
        for _, v in ipairs(ids) do
            if v == id then say(L('すでに選ばれています: ', 'Already selected: ') .. item_name(id)) return end
        end
        ids[#ids + 1] = id
        save_ids(ids)
        say(L('選びました: ', 'Selected: ') .. item_name(id))
    elseif cmd == 'remove' or cmd == 'rm' then
        local name = join_name(args, 1)
        if name == '' then say(L('//bo remove <アイテム名>', '//bo remove <item name>'), 123) return end
        local id, err = resolve_item(name)
        if not id then say(err, 123) return end
        local ids, out = selected_ids(), {}
        for _, v in ipairs(ids) do if v ~= id then out[#out + 1] = v end end
        save_ids(out)
        say(L('外しました: ', 'Removed: ') .. item_name(id))
    elseif cmd == 'clear' then
        save_ids({})
        say(L('選びを全部外しました', 'Cleared the selection'))
    elseif cmd == 'list' then
        show_list()
    elseif cmd == 'start' then
        local ids, dropped = selected_ids()
        if #dropped > 0 then
            say(L('res に無い ID を外しました: ', 'Skipped IDs not in the resources: ') .. table.concat(dropped, ', '), 123)
        end
        if #ids == 0 then
            say(L('開ける箱が選ばれていません。//bo add <アイテム名>', 'No boxes selected. //bo add <item name>'), 123)
            return
        end
        local first = normalize_amount(join_name(args, 1)):match('^(%S+)')
        local limit = first and tonumber(first) or nil
        if limit then limit = math.floor(limit) end
        if first and (not limit or limit < 1) then
            say(L('回数は 1 以上の数字で指定してください', 'The count must be a number, 1 or more'), 123)
            return
        end
        if not status_ok() then
            say(L('状態が通常ではありません (戦闘中・イベント中など)', 'Not in a normal state (fighting, in an event, etc.)'), 123)
            return
        end
        if start_job({kind = 'open', ids = ids, limit = limit, done = 0, fails = 0, since_sort = 0, state = 'pick'}) then
            say(string.format(L('開封を始めます (%s)。止めるには //bo stop か Ctrl+Esc', 'Start opening (%s). //bo stop or Ctrl+Esc to stop'),
                limit and (limit .. L(' 回', ' times')) or L('無くなるまで', 'until none left')))
        end
    elseif cmd == 'give' then
        local all = normalize_amount(join_name(args, 1))
        -- 先頭の「数」または all を読む。そのあとに付いた区切り (空白・| など) は名前の前から取り除く
        local amount, name = split_amount(all)
        local limit
        if amount == 'all' then limit = nil
        elseif amount then
            limit = tonumber(amount)
            if limit then limit = math.floor(limit) end
        end
        if not amount or (amount ~= 'all' and (not limit or limit < 1)) then
            say(L('//bo give <数|all> <アイテム名> [@NPC名]', '//bo give <n|all> <item name> [@NPC name]'), 123)
            local first = all:match('^(%S*)') or ''
            local hex = {}
            for i = 1, math.min(#first, 12) do hex[#hex + 1] = string.format('%02X', first:byte(i)) end
            say(L('数 (または all) が読めません: ', 'Cannot read the amount: ') .. first .. ' [' .. table.concat(hex, ' ') .. ']', 123)
            return
        end
        if name == '' then
            say(L('//bo give <数|all> <アイテム名> [@NPC名]', '//bo give <n|all> <item name> [@NPC name]'), 123)
            return
        end
        local npc_name
        local at = name:find(' @', 1, true)
        if at then npc_name = name:sub(at + 2); name = name:sub(1, at - 1) end
        local id, err, partial = resolve_item(name)
        if not id then say(err, 123) return end
        local npc_id, npc_label
        if not npc_name then
            local t = windower.ffxi.get_mob_by_target('t')
            if not npc_ok(t) then
                say(L('トレードする相手の NPC をターゲットしてください (6 歩以内。プレイヤー・モンスター・フェイス・ペットにはトレードしません)', 'Target the NPC to give to (within 6 yalms; never players, monsters, trusts or pets)'), 123)
                return
            end
            npc_id = t.id
            npc_label = t.name
        elseif find_npc_by_name(npc_name) then
            npc_label = npc_name
        else
            say(L('その名前の NPC が近くにいません: ', 'No such NPC nearby: ') .. npc_name, 123)
            return
        end
        if inv_count(id) == 0 and elsewhere_total(id) == 0 then
            say(L('かばんにも他のバッグにも無いアイテムです: ', 'Not in your inventory or other bags: ') .. item_name(id), 123)
            return
        end
        if not status_ok() then
            say(L('状態が通常ではありません', 'Not in a normal state'), 123)
            return
        end
        -- 名前の一部で決めたときは、違うアイテムなら止められるよう、最初のトレードまで GIVE_GRACE 秒待つ
        local delay = partial and GIVE_GRACE or 0
        -- 整頓の直後なら、並びが反映されるまで待つ
        delay = math.max(delay, last_sort + SORT_WAIT - os.clock())
        if start_job({kind = 'give', id = id, limit = limit, done = 0, since_sort = 0, state = 'pick', npc_id = npc_id, npc_name = npc_name, delay = delay}) then
            say(string.format(L('トレードを始めます: %s (%s) → %s。止めるには //bo stop か Ctrl+Esc', 'Start trading: %s (%s) to %s. //bo stop or Ctrl+Esc to stop'),
                item_name(id), limit and tostring(limit) or L('無くなるまで', 'all'), tostring(npc_label)))
            if partial then
                say(string.format(L('名前の一部で「%s」に決めました。%d 秒後に始めます。違うなら //bo stop', 'Matched "%s" by part of the name. Starting in %d s; //bo stop if wrong'),
                    item_name(id), GIVE_GRACE), 123)
            end
        end
    elseif cmd == 'stop' then
        if job then finish(L('中断しました', 'Cancelled'), 167) else say(L('実行中ではありません', 'Nothing is running')) end
    elseif cmd == 'reserve' then
        local n = tonumber(args[1])
        if not n or n < 0 or n > 80 then say(L('//bo reserve <0〜80>', '//bo reserve <0-80>'), 123) return end
        settings.reserve = math.floor(n)
        config.save(settings)
        say(L('かばんに残す空きを ', 'Free slots to keep: ') .. settings.reserve)
    elseif cmd == 'interval' then
        local n = tonumber(args[1])
        if not n or n < 1 or n > 30 then say(L('//bo interval <1〜30 秒>', '//bo interval <1-30 seconds>'), 123) return end
        settings.interval = n
        config.save(settings)
        say(L('開ける間隔を ', 'Interval: ') .. n .. L(' 秒にしました', ' s'))
    elseif cmd == 'sort' then
        local v = args[1] and args[1]:lower()
        if v == 'on' or v == 'off' then
            settings.autosort = (v == 'on')
            config.save(settings)
            say(L('自動の整頓: ', 'Auto sort: ') .. v)
        elseif v == nil then
            if job then say(L('実行中は手動で整頓できません (自動の整頓が働きます)', 'Cannot sort by hand while running (auto sort handles it)'), 123) return end
            do_sort(os.clock())
            say(L('かばんを整頓しました', 'Sorted the inventory'))
        elseif tonumber(v) then
            local n = math.floor(tonumber(v))
            if n < 1 or n > 100 then say(L('//bo sort <1〜100 回ごと>', '//bo sort <1-100 per>'), 123) return end
            settings.sort_every = n
            config.save(settings)
            say(L('整頓の間隔を ', 'Sort every ') .. n .. L(' 回ごとにしました', ' times'))
        else
            say('//bo sort [on|off|<n>]', 123)
        end
    elseif cmd == 'confirm' then
        local v = args[1] and args[1]:lower()
        if v ~= 'on' and v ~= 'off' then say('//bo confirm on|off', 123) return end
        settings.confirm = (v == 'on')
        config.save(settings)
        say(L('トレードのあとの決定キー: ', 'Confirm key after trades: ') .. v)
    elseif cmd == 'key' then
        local v = args[1] and args[1]:lower()
        if v ~= 'on' and v ~= 'off' then say('//bo key on|off', 123) return end
        settings.key = (v == 'on')
        config.save(settings)
        say(L('中断キー (Ctrl+Esc): ', 'Cancel key (Ctrl+Esc): ') .. v)
    elseif cmd == 'lang' then
        local v = args[1] and args[1]:lower()
        if v ~= 'auto' and v ~= 'ja' and v ~= 'en' then say('//bo lang auto|ja|en', 123) return end
        settings.lang = v
        config.save(settings)
        say(L('表示の言語を保存しました。読み込み直し (//lua r BoxOpener) で反映されます', 'Saved. Reload (//lua r BoxOpener) to apply'))
    elseif cmd == 'status' then
        say(string.format(L('実行: %s / 空き %d (残す %d) / 間隔 %.1f 秒 / 中断キー %s / 自動整頓 %s', 'Running: %s / free %d (keep %d) / interval %.1f s / cancel key %s / auto sort %s'),
            job and (job.kind .. ' ' .. job.done) or L('なし', 'no'), free_slots(), num(settings.reserve, 3), num(settings.interval, 3.0), tostring(settings.key), tostring(settings.autosort)))
        show_list()
    else
        show_help()
    end
end)
