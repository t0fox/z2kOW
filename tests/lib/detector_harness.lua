local fork=os.getenv('Z2K_FORK_DIR') or '../zapret2-z2k-fork'
local H=dofile(fork..'/tests/harness.lua')
assert(type(circular_report_failure)=='function','detector tests require the matching fork Lua revision')
dofile('files/lua/z2k-alert.lua')
dofile('files/lua/z2k-quic-silence.lua')
local tcp=H.tcp
H.tcp=function(...)
    local d=tcp(...); d.arg.failure_detector='z2k_fail_tls_alert'; d.arg.retrans='2'; return d
end
local udp=H.udp
H.udp=function(...)
    local d=udp(...); d.arg.failure_detector='z2k_fail_quic_silence'; return d
end
H.hello=string.char(0x16,3,3,0,42,2,0,0,38)..string.rep('\0',38)
H.alert=string.char(0x15,3,3,0,2,2,40)
H.client=string.char(0x16,3,3,0,100)..string.rep('x',100)
function H.http(track,seq,p)
    local d=H.tcp(track,false,seq,p,seq==1 and 'http_reply' or 'unknown')
    d.arg.key='http_rkn'; return d
end
local function u32(n)
    return string.char(math.floor(n/16777216)%256,math.floor(n/65536)%256,math.floor(n/256)%256,n%256)
end
function H.quic(kind,dcid,scid,version)
    version=version or 1; dcid=dcid or 'clientid'; scid=scid or 'serverid'
    if kind=='short' then return string.char(0x40)..dcid..string.rep('s',32) end
    local index=({initial=0,zero=1,handshake=2,retry=3})[kind]
    if version==0x6b3343cf then index=(index+1)%4 end
    local header=string.char(0xc0+index*16)..u32(version)..string.char(#dcid)..dcid..string.char(#scid)..scid
    if kind=='retry' then return header..'token'..string.rep('t',16) end
    return header..(kind=='initial' and '\0' or '')..string.char(32)..string.rep('s',32)
end
function H.qstart(track,version)
    return H.udp(track,true,H.quic('initial','destination','clientid',version),'quic_initial')
end
return H
