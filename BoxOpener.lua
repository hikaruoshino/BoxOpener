_addon.name = 'BoxOpener'
_addon.author = 'hikaruoshino'
_addon.version = '0.3.8'
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
--   confirm_key  : 決定キーの名前 (Windower の setkey のキー名。既定 enter)。要確認: ゲーム内未確認
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
local settings = config.load(defaults)

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

-- 名前から ID を探す。日本語名・英語名 (略称も) の完全一致。
local function find_item_exact(name)
    if not name or name == '' then return nil end
    local lower = name:lower()
    for id, row in pairs(res.items) do
        if type(row) == 'table' and (row.ja == name or row.jal == name
            or (row.en and row.en:lower() == lower) or (row.enl and row.enl:lower() == lower)) then
            return id
        end
    end
    return nil
end

-- 使えるバッグ (かばんの外)。持ち運べるもの → モグハウスのもの の順に探す
local OTHER_BAGS = {5, 6, 7, 1, 2, 4, 9}

local function bag_enabled(bag)
    local info = windower.ffxi.get_bag_info(bag)
    return info and info.enabled
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

local function resolve_item(name)
    local id = find_item_exact(name)
    if id then return id end
    local id2, n = find_item_owned(name)
    if id2 then return id2 end
    if n and n > 1 then
        return nil, L('名前が複数のアイテムに当てはまります: ', 'Several items match: ') .. name
    end
    return nil, L('アイテムが見つかりません: ', 'Unknown item: ') .. name
end

local function selected_ids()
    local ids = {}
    for part in tostring(settings.items or ''):gmatch('%d+') do
        ids[#ids + 1] = tonumber(part)
    end
    return ids
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

-- かばん (bag 0) の、そのアイテムの合計数 (装備中は除く)
local function inv_count(id)
    local items = windower.ffxi.get_items(0)
    local total = 0
    if not items then return 0 end
    for _, it in ipairs(items) do
        if it.id == id and (it.status or 0) == 0 then total = total + (it.count or 1) end
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

-- 終わるとき (回数に達した・アイテムが無くなった・空きが足りない) に、かばんを最後に 1 回整頓する。
-- 途中の整頓は N 回ごとなので、回数が N に届かない実行 (//bo start 10 など) でも、開けた中身の端数がまとまる
local function finish(reason, color, sort)
    if not job then return end
    local j = job
    job = nil
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
    job = j
    j.next_at = os.clock()
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
local SORT_WAIT = 2.0     -- 整頓の結果がかばんに反映されるのを待つ秒数
local SORT_GAP = 5.0      -- 整頓の最短の間隔
local function do_sort(now)
    windower.ffxi.stack_items(0)
    last_sort = now
end

-- 整頓するべきなら整頓して true (呼んだ側は state を wait_sort にして待つ)
local function maybe_sort(j, now)
    if not settings.autosort then return false end
    if now - last_sort < SORT_GAP then return false end
    local every = math.max(1, math.floor(num(settings.sort_every, 10)))
    if j.since_sort >= every or free_slots() < num(settings.reserve, 3) + 2 then
        j.since_sort = 0
        do_sort(now)
        j.sort_until = now + SORT_WAIT
        j.state = 'wait_sort'
        return true
    end
    return false
end

-- 状態が通常 (0) でないときは動かさない (戦闘中・イベント中・倒れている等)
local function status_ok()
    local s = player_status()
    return s == 0
end

----- 開封 -----

local function open_step(now)
    local j = job

    if j.state == 'wait_sort' then
        if now >= j.sort_until then j.state = 'pick' end
        return
    end

    if j.state == 'wait_move' then
        if inv_count(j.cur) > j.before then
            j.state = 'pick'
            j.next_at = now + 0.5
            return
        end
        if now > j.deadline then return finish(L('かばんへの移動が確認できませんでした', 'The move into the inventory was not confirmed'), 123) end
        return
    end

    if j.state == 'wait_use' then
        local c = inv_count(j.cur)
        if c < j.before then
            j.done = j.done + 1
            j.since_sort = j.since_sort + 1
            j.fails = 0
            j.state = 'pick'
            j.next_at = now + num(settings.interval, 3.0)
            return
        end
        if now > j.deadline then
            j.fails = j.fails + 1
            if j.fails >= 2 then
                return finish(L('開けても数が減りません (2 回続けて)。他の行動中・かばんの空き不足・使えない場所の可能性があります', 'The count does not drop after using (twice in a row): busy, no room, or cannot use here'), 123)
            end
            j.state = 'pick'
            j.next_at = now + num(settings.interval, 3.0)
        end
        return
    end

    -- state == 'pick': 次の 1 回を始める前の確認
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
    local cur
    for _, id in ipairs(j.ids) do
        if inv_count(id) > 0 or elsewhere_total(id) > 0 then cur = id break end
    end
    if not cur then
        return finish(L('開けるアイテムが無くなりました', 'No more items to open'), 207, true)
    end
    j.cur = cur

    if inv_count(cur) == 0 then
        -- かばんに無いので、ほかのバッグから 1 枠ぶん持ってくる
        local at = find_elsewhere(cur)
        if not at then
            return finish(L('開けるアイテムが無くなりました', 'No more items to open'), 207, true)
        end
        if free_slots() < num(settings.reserve, 3) + 1 then
            return finish(L('かばんの空きが足りません', 'Not enough free inventory slots'), 123, true)
        end
        j.before = inv_count(cur)
        -- 回数を決めているときは、残りの回数ぶんだけ持ってくる (余りをかばんに持ち込まない)
        local take = j.limit and math.max(1, math.min(at.count, j.limit - j.done)) or at.count
        windower.ffxi.move_item(at.bag, 0, at.slot, take)
        j.state = 'wait_move'
        j.deadline = now + 6
        return
    end

    j.before = inv_count(cur)
    local name = (CLIENT_JA and (res.items[cur].ja or res.items[cur].en)) or res.items[cur].en or res.items[cur].ja
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

-- かばんの、そのアイテムが入っている枠の数
local function inv_stacks(id)
    local items = windower.ffxi.get_items(0)
    local n = 0
    for _, it in ipairs(items or {}) do
        if it.id == id and (it.status or 0) == 0 and (it.count or 0) > 0 then n = n + 1 end
    end
    return n
end

-- かばんの、そのアイテムの枠 (装備中は除く) を順に集めて、最大 8 枠ぶんのトレードを組み立てる
local function build_trade(id, want)
    local items = windower.ffxi.get_items(0)
    local ind, qty = {}, {}
    local left = want
    for k, it in ipairs(items or {}) do
        if #ind >= 8 or left <= 0 then break end
        if it.id == id and (it.status or 0) == 0 and (it.count or 0) > 0 then
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
        if now >= j.sort_until then j.state = 'pick' end
        return
    end

    if j.state == 'wait_move' then
        if inv_count(j.id) > j.before then
            j.state = 'pick'
            j.next_at = now + 0.5
            return
        end
        if now > j.deadline then return finish(L('かばんへの移動が確認できませんでした', 'The move into the inventory was not confirmed'), 123) end
        return
    end

    if j.state == 'wait_trade' then
        local c = inv_count(j.id)
        if c <= j.before - j.expect then
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
                if j.presses >= math.max(1, math.floor(num(settings.confirm_max, 8))) then
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
    local have = inv_count(j.id)
    if j.limit and j.done >= j.limit then
        return finish(L('指定した数に達しました', 'Reached the requested amount'), 207, true)
    end
    if not status_ok() then
        return finish(L('状態が通常ではありません', 'Not in a normal state'), 123)
    end
    if maybe_sort(j, now) then return end
    -- かばんの分が 1 回 (8 枠) ぶんに足りないなら、ほかのバッグから 1 枠ぶん持ってくる
    local need = j.limit and (j.limit - j.done) or math.huge
    if inv_stacks(j.id) < 8 and have < need and free_slots() >= num(settings.reserve, 3) + 1 then
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
    local want = j.limit and math.min(j.limit - j.done, have) or have
    local ind, qty = build_trade(j.id, want)
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

windower.register_event('prerender', function()
    if not job then return end
    local now = os.clock()
    if now < job.next_at then return end
    if job.kind == 'open' then open_step(now) else give_step(now) end
    if job then job.next_at = math.max(job.next_at, now + 0.25) end
end)

windower.register_event('zone change', function()
    if job then finish(L('ゾーンを移動しました', 'Changed zones'), 167) end
end)

local function release_confirm_key()
    windower.send_command('setkey ' .. tostring(settings.confirm_key or 'enter') .. ' up')
end

windower.register_event('unload', function()
    if job then
        job = nil
        release_confirm_key()
    end
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
        local here, there = inv_count(id), elsewhere_total(id)
        say(string.format(L('%d. %s  (かばん %d / ほかのバッグ %d)', '%d. %s  (inventory %d / other bags %d)'), i, item_name(id), here, there))
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
-- 全角の空白 (U+3000) は ASCII の空白に、全角の数字 (U+FF10〜FF19) は ASCII の数字に直す。
-- 日本語入力のまま「101　餅鉄」と打つと、空白で区切られず 1 つの語として届くため
local function normalize(str)
    str = str:gsub('\227\128\128', ' ')
    str = str:gsub('\239\188([\144-\153])', function(c) return string.char(c:byte() - 144 + 48) end)
    return str
end

local function join_name(args, from, to)
    local parts = {}
    for i = from, to or #args do parts[#parts + 1] = normalize(from_sjis(args[i])) end
    return (table.concat(parts, ' '):gsub('^%s+', ''))
end

windower.register_event('addon command', function(cmd, ...)
    local args = {...}
    cmd = cmd and cmd:lower() or 'help'

    if cmd == 'add' then
        local name = join_name(args, 1)
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
        local ids = selected_ids()
        if #ids == 0 then
            say(L('開ける箱が選ばれていません。//bo add <アイテム名>', 'No boxes selected. //bo add <item name>'), 123)
            return
        end
        local first = join_name(args, 1):match('^(%S+)')
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
        local all = join_name(args, 1)
        -- 先頭の「数」または all を読む。そのあとに付いた区切り (空白・| など) は名前の前から取り除く
        local amount, name = all:match('^(%d+)(.*)$')
        if not amount then
            amount, name = all:match('^([Aa][Ll][Ll])(.*)$')
            amount = amount and amount:lower()
        end
        local limit
        if amount == 'all' then limit = nil
        elseif amount then
            limit = tonumber(amount)
            if limit then limit = math.floor(limit) end
        end
        if amount then name = name:gsub('^[%s|]+', '') end
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
        local id, err = resolve_item(name)
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
        if start_job({kind = 'give', id = id, limit = limit, done = 0, since_sort = 0, state = 'pick', npc_id = npc_id, npc_name = npc_name}) then
            say(string.format(L('トレードを始めます: %s (%s) → %s。止めるには //bo stop か Ctrl+Esc', 'Start trading: %s (%s) to %s. //bo stop or Ctrl+Esc to stop'),
                item_name(id), limit and tostring(limit) or L('無くなるまで', 'all'), tostring(npc_label)))
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
