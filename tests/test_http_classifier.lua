local H=dofile('tests/lib/detector_harness.lua')
local function classify(p) return z2k_classify_http_reply(H.http(nil,1,p)) end
H.test('normal 200, 304 and relative redirects are positive',function()
    H.eq('positive',classify('HTTP/1.1 200 OK\r\n\r\nhello'))
    H.eq('positive',classify('HTTP/1.1 304 Not Modified\r\n\r\n'))
    H.eq('positive',classify('HTTP/1.1 302 Found\r\nLocation: /login\r\n\r\n'))
end)
H.test('ordinary cross-domain redirects are neutral',function()
    H.eq('neutral',classify('HTTP/1.1 302 Found\r\nLocation: https://login.example.org/\r\n\r\n'))
end)
H.test('known portals are detected in absolute and scheme-relative redirects',function()
    for _,url in ipairs({'https://warning.rt.ru/', '//eais.rkn.gov.ru/blocked'}) do
        H.eq('hard_fail',classify('HTTP/1.1 302 Found\r\nLocation: '..url..'\r\n\r\n'))
    end
end)
H.test('marker-like domains and paths are not portals',function()
    for _,url in ipairs({'https://sparknotes.com/', 'https://warning.example.org/', 'https://warning.rt.ru.evil.example/', 'https://other.example/rkn'}) do
        H.eq('neutral',classify('HTTP/1.1 302 Found\r\nLocation: '..url..'\r\n\r\n'))
    end
end)
H.test('bare 451, WAF and ordinary error prose remain neutral',function()
    for _,p in ipairs({'HTTP/1.1 451 Unavailable\r\n\r\n', 'HTTP/1.1 403 Forbidden\r\nX-Vercel-Mitigated: deny\r\n\r\n', 'HTTP/1.1 403 Forbidden\r\n\r\nSparkNotes account expired'}) do
        H.eq('neutral',classify(p))
    end
end)
H.test('known block portal in error body is detected',function()
    H.eq('hard_fail',classify('HTTP/1.1 403 Forbidden\r\n\r\n<a href="https://eais.rkn.gov.ru/">blocked</a>'))
end)
H.test('authority in Link header is not a body marker',function()
    H.eq('neutral',classify('HTTP/1.1 451 Unavailable\r\nLink: <https://eais.rkn.gov.ru/>; rel="blocked-by"\r\n\r\n'))
end)
H.test('compressed payload is not scanned as plaintext',function()
    H.eq('neutral',classify('HTTP/1.1 403 Forbidden\r\nContent-Encoding: gzip\r\n\r\naccess blocked by rkn'))
end)
H.test('incomplete or invalid headers are not successful redirects',function()
    H.eq('neutral',classify('HTTP/1.1 302 Found\r\nLocation: https://warning.rt.ru/'))
    H.eq(nil,classify('garbage'))
end)
H.test('classifier ignores outgoing data',function()
    local d=H.http(nil,1,'HTTP/1.1 200 OK\r\n\r\n'); d.outgoing=true
    H.eq(nil,z2k_classify_http_reply(d))
end)
H.finish()
