-- Проверка записи и повторного чтения persistent-состояния под WS_USER.
local mode = assert(arg[1], "нужен режим write или restore")

autostate = {}
function standard_hostkey(desync)
  return desync and desync.track and desync.track.hostname
end
function circular()
  return 0
end

dofile("files/lua/z2k-state-persist.lua")
local persist = assert(z2k_state_persist, "слой сохранения не загрузился")
local desync = {
  arg = { key = "yt_tcp" },
  track = { hostname = "youtube.com" },
}
local key, host, record = persist.get_record(desync, true)
assert(key == "yt_tcp" and host == "youtube.com" and record,
       "не получена запись кругового профиля YouTube")

if mode == "write" then
  record.nstrategy = 7
  assert(persist.persist_if_changed(key, host, record),
         "новая стратегия не поставлена в очередь записи")
  -- persist_if_changed() пишет сразу; повторный flush может попасть в окно debounce.
  persist.flush()
elseif mode == "restore" then
  assert(tonumber(record.nstrategy) == 7,
         "стратегия не восстановилась из постоянного файла")
else
  error("неизвестный режим: " .. tostring(mode))
end
