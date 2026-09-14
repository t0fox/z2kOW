-- Integration regressions: production dispatcher, native detectors and parsers.
local H=dofile('tests/lib/detector_harness.lua')
H.test('early fatal alert is counted once, without sending RST',function()
    local d=H.tcp(nil,true,1,H.client,'tls_client_hello'); H.step(d)
    local reply=H.tcp(d.track,false,1,H.alert); local h,c=H.step(reply); H.step(reply)
    H.eq(true,c.failure); H.eq(1,h.failure_counter); H.eq(0,#H.sent)
end)
H.test('split fatal alert, including reordered pieces, is reassembled',function()
    for _,reverse in ipairs({false,true}) do
        local t=H.track(reverse and 'reordered.example' or 'split.example')
        H.step(H.tcp(t,true,1,H.client,'tls_client_hello'))
        if reverse then H.step(H.tcp(t,false,6,H.alert:sub(6))) end
        local h,c=H.step(H.tcp(t,false,1,H.alert:sub(1,5)))
        if not reverse then h,c=H.step(H.tcp(t,false,6,H.alert:sub(6))) end
        H.eq(true,c.failure); H.eq(1,h.failure_counter)
    end
end)
H.test('ServerHello followed by alert is outside the plaintext early-alert scope',function()
    local d=H.tcp(nil,false,1,H.hello,'tls_server_hello'); H.step(d)
    local h,c=H.step(H.tcp(d.track,false,#H.hello+1,H.alert))
    H.eq(true,c.server_hello); H.eq(nil,c.failure); H.eq(nil,h.failure_counter)
end)
H.test('protected TLS records are not parsed as plaintext fatal alerts',function()
    local p=string.char(0x15,3,3,0,32,2)..string.rep('x',31)
    local h,c=H.step(H.tcp(nil,false,1,p))
    H.eq(true,c.neutral); H.eq(nil,h.failure_counter)
end)
H.test('warning close_notify is neutral',function()
    local h,c=H.step(H.tcp(nil,false,1,string.char(0x15,3,3,0,2,1,0)))
    H.eq(true,c.neutral); H.eq(nil,h.failure_counter)
end)
H.test('three sibling ServerHellos cannot suppress a failed handshake',function()
    for i=1,3 do H.step(H.tcp(H.track('cdn'..i..'.review.example'),false,1,H.hello,'tls_server_hello')) end
    local h,c=H.step(H.tcp(H.track('broken.review.example'),false,1,H.alert))
    H.eq(true,c.failure); H.eq(1,h.failure_counter)
end)
H.test('ClientHello tail retransmissions retain native counting and one accepted reset',function()
    local d=H.tcp(nil,true,1,H.client:sub(1,40),'tls_client_hello'); H.step(d)
    local h,c
    for i=1,4 do h,c=H.step(H.tcp(d.track,true,41,H.client:sub(41),'unknown',true)) end
    H.eq(true,c.failure); H.eq(1,h.failure_counter); H.eq(1,#H.sent)
end)
H.test('application-data retransmissions after the first request are ignored',function()
    local d=H.tcp(nil,true,1,H.client,'tls_client_hello'); H.step(d)
    local h,c
    for i=1,4 do h,c=H.step(H.tcp(d.track,true,#H.client+1,'app data','unknown',true)) end
    H.eq(nil,c.failure); H.eq(nil,h.failure_counter); H.eq(0,#H.sent)
end)
H.test('HTTP request header continuation is included but keepalive second request is not',function()
    local request='GET / HTTP/1.1\r\nHost: review.example\r\n\r\n'
    local d=H.tcp(nil,true,1,request:sub(1,20),'http_req'); H.step(d)
    H.step(H.tcp(d.track,true,21,request:sub(21),'unknown'))
    local h,c
    for i=1,3 do h,c=H.step(H.tcp(d.track,true,#request+1,request,'http_req',true)) end
    H.eq(nil,c.failure)
    for i=1,3 do h,c=H.step(H.tcp(d.track,true,21,request:sub(21),'unknown',true)) end
    H.eq(true,c.failure); H.eq(1,h.failure_counter)
end)
H.test('RST with payload does not authenticate its own TTL',function()
    local d=H.tcp(nil,false,1,'injected'); d.dis.tcp.th_flags=TH_RST+TH_ACK
    local h,c=H.step(d); H.eq(true,c.failure); H.eq(1,h.failure_counter)
end)
H.test('server-matching TTL cannot veto an early RST',function()
    local d=H.tcp(nil,false,1,H.hello,'tls_server_hello'); H.step(d)
    local rst=H.tcp(d.track,false,#H.hello+1,''); rst.dis.tcp.th_flags=TH_RST+TH_ACK
    local _,c=H.step(rst); H.eq(true,c.failure)
end)
H.test('zero-window probes do not rotate the host',function()
    local d=H.tcp(nil,false,1,H.hello,'tls_server_hello'); H.step(d)
    local h,c
    for i=1,6 do
        local probe=H.tcp(d.track,false,100,'x','unknown',true); probe.track.pos.reverse.tcp.winsize=0
        h,c=H.step(probe)
    end
    H.eq(nil,c.failure); H.eq(nil,h.failure_counter)
end)
H.test('client FIN does not hide a subsequent server fatal alert',function()
    local d=H.tcp(nil,true,1,H.client,'tls_client_hello'); H.step(d)
    local fin=H.tcp(d.track,true,#H.client+1,''); fin.dis.tcp.th_flags=TH_FIN+TH_ACK; H.step(fin)
    local _,c=H.step(H.tcp(d.track,false,1,H.alert)); H.eq(true,c.failure)
end)
H.test('HTTP block body split from headers still fails',function()
    local header='HTTP/1.1 403 Forbidden\r\nContent-Length: 21\r\n\r\n'
    local d=H.http(nil,1,header); H.step(d)
    local h,c=H.step(H.http(d.track,#header+1,'access blocked by rkn'))
    H.eq(true,c.failure); H.eq(1,h.failure_counter)
end)
H.test('ordinary cross-domain 302 is neutral, not a native redirect failure',function()
    for i=1,3 do
        local h,c=H.step(H.http(nil,1,'HTTP/1.1 302 Found\r\nLocation: https://login.example.org/\r\n\r\n'))
        H.eq(true,c.neutral); H.eq(nil,c.failure); H.eq(1,h.nstrategy)
    end
end)
H.test('explicit block-portal redirect fails',function()
    local _,c=H.step(H.http(nil,1,'HTTP/1.1 302 Found\r\nLocation: https://warning.rt.ru/\r\n\r\n'))
    H.eq(true,c.failure)
end)
H.test('SparkNotes error text is not rkn',function()
    local _,c=H.step(H.http(nil,1,'HTTP/1.1 403 Forbidden\r\nContent-Length: 10\r\n\r\nSparkNotes'))
    H.eq(true,c.neutral); H.eq(nil,c.failure)
end)
H.test('large HTTP error is classified before native byte success',function()
    local d=H.http(nil,1,'HTTP/1.1 403 Forbidden\r\nContent-Length: 9000\r\n\r\n'); H.step(d)
    local h=automate_host_record(d); h.failure_counter=2
    H.step(H.http(d.track,1000,string.rep('x',1000))) -- gap: no terminal success
    H.step(H.http(d.track,4201,string.rep('x',500)))
    H.eq(2,h.failure_counter); H.eq(nil,d.track.lua_state.automate.nocheck)
end)
H.test('conflicting prefix overlap is neutral, not a forged block signature',function()
    local d=H.http(nil,1,'HTTP/1.1 403'); H.step(d)
    local _,c=H.step(H.http(d.track,1,'HTTP/1.1 451'))
    H.eq(true,c.neutral); H.eq(nil,c.failure)
end)
H.test('bounded response buffer terminates inconclusively at cap',function()
    local _,c=H.step(H.http(nil,1,'HTTP/1.1 403 '..string.rep('x',5000)))
    H.eq(true,c.neutral); H.eq(nil,c.response_prefix)
end)
H.test('confirmed small HTTP 200 resets failures',function()
    local d=H.http(nil,1,'HTTP/1.1 200 OK\r\n'); local h=H.step(d); h.failure_counter=2
    local _,c=H.step(H.http(d.track,#d.dis.payload+1,'Content-Length: 0\r\n\r\n'))
    H.eq(true,c.nocheck); H.eq(nil,c.neutral); H.eq(nil,h.failure_counter)
end)
H.test('two retransmissions fail one attempt; three failed connections rotate',function()
    local h
    for attempt=1,3 do
        local d=H.tcp(nil,true,1,H.client,'tls_client_hello'); local c
        h,c=H.step(d)
        H.step(H.tcp(d.track,true,1,H.client,'tls_client_hello',true))
        H.eq(nil,c.failure); H.eq(attempt-1,#H.sent)
        H.step(H.tcp(d.track,true,1,H.client,'tls_client_hello',true))
        H.eq(true,c.failure); H.eq(attempt,#H.sent)
        H.eq(attempt==3 and 2 or 1,h.nstrategy)
    end
end)
H.test('a single lost packet can recover without reset or rotation',function()
    local d=H.tcp(nil,true,1,H.client,'tls_client_hello'); local h,c=H.step(d)
    H.step(H.tcp(d.track,true,1,H.client,'tls_client_hello',true))
    H.step(H.tcp(d.track,false,1,H.hello,'tls_server_hello'))
    H.step(H.tcp(d.track,false,4200,'fresh application progress'))
    H.eq(true,c.nocheck); H.eq(nil,c.failure); H.eq(0,#H.sent); H.eq(1,h.nstrategy)
end)
H.finish()
