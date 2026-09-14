local H=dofile('tests/lib/detector_harness.lua')
dofile('files/lua/z2k-state-persist.lua')
local P=z2k_state_persist
local path=os.getenv('Z2K_STATE_DIR_OVERRIDE')..'/state.tsv'
local function row(host)
    local f=assert(io.open(path)); local n
    for line in f:lines() do
        local key,h,s=line:match('^(%S+)\t([^\t]+)\t(%d+)')
        if key=='yt_quic' and h==host..'|4' then n=tonumber(s) end
    end
    f:close(); return n
end
H.test('QUIC timer persists rotation without waiting for another packet',function()
    local h
    for i=1,3 do h=H.step(H.qstart(H.track('timer.example'))) end
    H.advance(6)
    H.eq(2,h.nstrategy); H.eq(2,row('timer.example'))
end)
H.test('debounced timer result is flushed even if traffic stops',function()
    P._reset()
    for i=1,3 do H.step(H.qstart(H.track('deferred.example'))) end
    H.advance(4)
    H.step(H.qstart(H.track('other.example'))) -- occupies the shared write debounce
    H.advance(1.1)
    H.eq(2,autostate.yt_quic['deferred.example|4'].nstrategy)
    H.advance(2)
    H.eq(2,row('deferred.example'))
end)
H.test('operator freeze on disk wins over a pending QUIC timer without new packets',function()
    P._reset()
    local h
    for i=1,3 do h=H.step(H.qstart(H.track('frozen.example'))) end
    H.advance(4)
    H.step(H.qstart(H.track('recent-reconcile.example')))
    H.advance(0.5)
    local f=assert(io.open(path,'w'))
    f:write('yt_quic\tfrozen.example|4\t1\t1003\tfrozen\n'); f:close()
    H.advance(1)
    H.eq(1,h.nstrategy); H.eq(nil,h.failure_counter); H.eq(1,row('frozen.example'))
end)
H.finish()
