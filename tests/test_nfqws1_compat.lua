-- tests/test_nfqws1_compat.lua — badseq и hostfakesplit altorder=1 из
-- files/lua/z2k-nfqws1-compat.lua поверх настоящих zapret-lib/zapret-antidpi.
-- luacheck: globals rawsend_payload_segmented direction_cutoff_opposite instance_cutoff_shim direction_check payload_check replay_first replay_drop_set replay_drop resolve_range resolve_pos brandom_az brandom_az09 VERDICT_DROP
local fork=os.getenv('Z2K_FORK_DIR') or '../zapret2-z2k-fork'
local H=dofile(fork..'/tests/harness.lua')
dofile(fork..'/lua/zapret-antidpi.lua')
VERDICT_DROP=1
local upstream_hostfakesplit=hostfakesplit
local upstream_apply_fooling=apply_fooling
dofile('files/lua/z2k-nfqws1-compat.lua')
assert(hostfakesplit~=upstream_hostfakesplit and apply_fooling~=upstream_apply_fooling,'module must override both globals')

local M=4294967296
local function dis_tcp() return {ip={ip_ttl=64},tcp={th_seq=1000,th_ack=500000,th_flags=24,options={}},payload='x'} end
local desync={arg={}}

H.test('badseq alone: nfqws1 defaults seq-10000 ack-66000',function()
    local d=dis_tcp(); apply_fooling(desync,d,{badseq=true})
    H.eq((1000-10000)%M,d.tcp.th_seq); H.eq(500000-66000,d.tcp.th_ack)
end)
H.test('badseq_increment=0: seq untouched, ack still shifted (winws config idiom)',function()
    local d=dis_tcp(); apply_fooling(desync,d,{badseq=true,badseq_increment='0'})
    H.eq(1000,d.tcp.th_seq); H.eq(500000-66000,d.tcp.th_ack)
end)
H.test('badseq_increment=10000000 as in winws reference configs',function()
    local d=dis_tcp(); apply_fooling(desync,d,{badseq=true,badseq_increment='10000000'})
    H.eq(1000+10000000,d.tcp.th_seq); H.eq(500000-66000,d.tcp.th_ack)
end)
H.test('badack_increment overrides the ack default',function()
    local d=dis_tcp(); apply_fooling(desync,d,{badseq=true,badseq_increment='2',badack_increment='-5'})
    H.eq(1002,d.tcp.th_seq); H.eq(499995,d.tcp.th_ack)
end)
H.test('explicit tcp_seq/tcp_ack win over badseq defaults',function()
    local d=dis_tcp(); apply_fooling(desync,d,{badseq=true,tcp_seq='7',tcp_ack='3'})
    H.eq(1007,d.tcp.th_seq); H.eq(500003,d.tcp.th_ack)
end)
H.test('badseq=N short form is the increment',function()
    local d=dis_tcp(); apply_fooling(desync,d,{badseq='1000'})
    H.eq(2000,d.tcp.th_seq); H.eq(500000-66000,d.tcp.th_ack)
end)
H.test('without badseq the fooling table passes through untouched',function()
    local d=dis_tcp(); local opts={tcp_seq='5',badsum=true}
    apply_fooling(desync,d,opts)
    H.eq(1005,d.tcp.th_seq); H.eq(500000,d.tcp.th_ack); H.eq(nil,opts.tcp_ack)
end)
H.test('fooling taken from desync.arg when options omitted',function()
    local d=dis_tcp(); apply_fooling({arg={badseq=true,badseq_increment='2'}},d,nil)
    H.eq(1002,d.tcp.th_seq); H.eq(500000-66000,d.tcp.th_ack)
end)
H.test('badseq does not touch udp',function()
    local d={ip={ip_ttl=64},udp={},payload='x'}
    apply_fooling(desync,d,{badseq=true}); H.eq(nil,d.tcp)
end)

-- hostfakesplit: стабы вокруг порядка отправки; разбор позиций хоста настоящий
local sent
rawsend_payload_segmented=function(_d,payload,seq,opts)
    sent[#sent+1]={payload=payload,seq=seq,fake=(opts.fooling==_d.arg)}; return true
end
direction_cutoff_opposite=function() end
instance_cutoff_shim=function() end
direction_check=function() return true end
payload_check=function() return true end
replay_first=function() return true end
replay_drop_set=function() end
replay_drop=function() return false end
local REQ='GET / HTTP/1.1\r\nHost: www.example.com\r\nUser-Agent: x\r\n\r\n'
local HOST_AT=REQ:find('www.example.com',1,true)-1   -- нулевой индекс
local HOST_END=HOST_AT+#'www.example.com'
-- resolve_range/resolve_pos — функции ядра nfqws2 (C), в lua-тесте их нет:
-- отдаём позиции хоста так, как их отдаёт ядро (с единицы, конец включительно).
resolve_range=function(data,_l7,markers,_strict)
    assert(markers=='host,endhost-1'); assert(data==REQ)
    return {HOST_AT+1,HOST_END}
end
brandom_az=function(n) return string.rep('a',n) end   -- ядро: случайные символы для genhost
brandom_az09=function(n) return string.rep('b',n) end
resolve_pos=function(data,_l7,marker)
    assert(marker=='midsld'); return data:find('example',1,true)+3   -- середина sld
end
local function run(arg)
    sent={}
    local d={arg=arg,l7payload='http_req',dis={ip={ip_ttl=64},tcp={th_seq=1,th_ack=1,th_flags=24,options={}},payload=REQ},outgoing=true}
    return hostfakesplit(nil,d)
end
local function shape() local t={} for i,s in ipairs(sent) do t[i]=(s.fake and 'F' or 'O')..s.seq..':'..#s.payload end return table.concat(t,' ') end

H.test('upstream order kept when altorder is absent: before, fake, real, fake, after',function()
    H.eq(VERDICT_DROP,run({host='mail.ru'}))
    H.eq(5,#sent)
    H.eq('O0:'..HOST_AT..' F'..HOST_AT..':15 O'..HOST_AT..':15 F'..HOST_AT..':15 O'..HOST_END..':'..(#REQ-HOST_END),shape())
end)
H.test('altorder=1: before, fake, after, then the real host last',function()
    H.eq(VERDICT_DROP,run({host='mail.ru',altorder='1'}))
    H.eq(4,#sent)
    H.eq('O0:'..HOST_AT..' F'..HOST_AT..':15 O'..HOST_END..':'..(#REQ-HOST_END)..' O'..HOST_AT..':15',shape())
    H.eq('www.example.com',sent[4].payload)
    assert(sent[2].payload~='www.example.com' and sent[2].payload:sub(-7)=='mail.ru','fake host built from template')
end)
H.test('altorder=1 with midhost splits the trailing real host in two',function()
    H.eq(VERDICT_DROP,run({host='mail.ru',altorder='1',midhost='midsld'}))
    H.eq(5,#sent)
    H.eq(sent[4].payload..sent[5].payload,'www.example.com')
    H.eq(sent[4].seq+#sent[4].payload,sent[5].seq)
    H.eq(HOST_END,sent[3].seq)
end)
H.test('altorder=1 nofake1 drops the single fake',function()
    H.eq(VERDICT_DROP,run({host='mail.ru',altorder='1',nofake1=true}))
    H.eq(3,#sent); H.eq(false,sent[1].fake and sent[2].fake and sent[3].fake)
end)
H.test('altorder=0 is the upstream order',function()
    run({host='mail.ru',altorder='0'}); H.eq(5,#sent)
end)
H.test('altorder=1 nodrop passes the original',function()
    H.eq(VERDICT_PASS,run({host='mail.ru',altorder='1',nodrop=true}))
end)
H.finish()
