-- Early TCP failures beyond the standard RST/retransmission detector.
-- No host-liveness veto, TTL attribution or incoming-retransmission heuristic.
-- circular owns attempt identity, terminal results, rotation and optional RST.
-- The second return value is part of the fork's detector contract:
-- pending = keep observing; neutral = stop without changing the host counter.

local RESPONSE_LIMIT = 4096
local REQUEST_LIMIT = 32768
local BLOCK_PORTALS = {
    ["eais.rkn.gov.ru"] = true,
    ["lawfilter.ertelecom.ru"] = true,
    ["blackhole.svyaztelecom.ru"] = true,
    ["warning.rt.ru"] = true,
    ["warn.beeline.ru"] = true,
    ["deny.megafon.ru"] = true,
}

local function body_marker(body)
    local low = body:lower()
    for domain in pairs(BLOCK_PORTALS) do
        -- A complete hostname, not rkn inside SparkNotes or a URL suffix.
        if (" " .. low .. " "):find("[^%w_.%-]" .. domain:gsub("%.", "%%.") .. "[^%w_.%-]") then
            return domain
        end
    end
    -- Specific block-page wording; individual words are not signatures.
    if low:find("access blocked by rkn", 1, true) then return "blocked_by_rkn" end
end

local function location_host(value)
    if not value then return nil end
    local authority = value:match("^%s*[Hh][Tt][Tt][Pp][Ss]?://([^/%s?#]+)")
        or value:match("^%s*//([^/%s?#]+)")
    if not authority then return nil end
    authority = authority:match("([^@]+)$")
    return authority:gsub(":%d+$", ""):gsub("%.$", ""):lower()
end

function z2k_classify_http_reply(desync)
    if not desync or desync.outgoing or desync.l7payload ~= "http_reply" then return nil end
    local p = desync.dis and desync.dis.payload
    if type(p) ~= "string" then return nil end
    local code = tonumber(p:match("^HTTP/1%.[01]%s+(%d%d%d)%s"))
    if not code then return nil end
    local split = p:find("\r\n\r\n", 1, true)
    if not split then return "neutral", "incomplete_headers" end
    local headers, body = p:sub(1, split + 1):lower(), p:sub(split + 4)
    if code >= 400 and code < 600 then
        -- Compressed bodies cannot be classified by plaintext substring scans.
        local encoding = headers:match("\r\ncontent%-encoding:%s*([^\r\n]+)")
        if encoding and encoding ~= "identity" then return "neutral", "encoded_body" end
        local marker = body_marker(body)
        if marker then return "hard_fail", "http_block_portal:" .. marker end
        return "neutral", "http_error_without_signature"
    end
    if code >= 200 and code < 300 or code == 304 then return "positive" end
    if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
        local location = p:match("\r\n[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[ \t]*([^\r\n]+)")
        local target = location_host(location)
        if target and BLOCK_PORTALS[target] then return "hard_fail", "http_redirect_portal:" .. target end
        if location and location:match("^/[^/]") then return "positive" end
        local host = desync.track and desync.track.hostname
        if target and host and target == host:lower():gsub(":%d+$", ""):gsub("%.$", "") then return "positive" end
        -- A cross-domain redirect is ordinary navigation, not proof of DPI.
        return "neutral", "http_redirect"
    end
    return "neutral", "http_other_status"
end

-- Bounded prefix reassembly. Handles gaps, retransmissions and matching
-- overlaps. Conflicting overlaps are inconclusive, never a block signature.
local function prefix_add(state, seq, payload, limit)
    if state.bad then return false end
    if seq < 1 or seq > limit or #payload == 0 then return true end
    payload = payload:sub(1, limit - seq + 1)
    local data = state.data or ""
    local overlap = math.min(#payload, #data - seq + 1)
    if overlap > 0 and data:sub(seq, seq + overlap - 1) ~= payload:sub(1, overlap) then
        state.bad = true
        return false
    end
    if seq <= #data + 1 then
        if seq + #payload - 1 > #data then state.data = data .. payload:sub(#data - seq + 2) end
    else
        state.parts = state.parts or {}
        state.bytes = (state.bytes or 0) + #payload
        if #state.parts >= 16 or state.bytes > limit * 2 then state.bad = true; return false end
        state.parts[#state.parts + 1] = { seq, payload }
    end
    local changed = true
    while changed and state.parts do
        changed = false
        for i = #state.parts, 1, -1 do
            local part = state.parts[i]
            if part[1] <= #(state.data or "") + 1 then
                table.remove(state.parts, i)
                state.bytes = state.bytes - #part[2]
                if not prefix_add(state, part[1], part[2], limit) then return false end
                changed = true
                break
            end
        end
    end
    return true
end

local function record_length(p)
    if #p < 5 or p:byte(2) ~= 3 or p:byte(3) > 3 then return nil end
    return p:byte(4) * 256 + p:byte(5)
end

local function first_request(desync, crec)
    local p, seq = desync.dis.payload or "", pos_get(desync, 's')
    if not crec.request_start then
        if desync.l7payload ~= "tls_client_hello" and desync.l7payload ~= "http_req" then return end
        crec.request_start = seq
        crec.request_kind = desync.l7payload
        if crec.request_kind == "tls_client_hello" then
            local len = record_length(desync.reasm_data or p)
            if len and len + 5 <= REQUEST_LIMIT then crec.request_end = seq + len + 5 end
        else
            crec.request_prefix = {}
        end
    end
    if crec.request_prefix then
        local start = seq - crec.request_start + 1
        if not prefix_add(crec.request_prefix, start, p, RESPONSE_LIMIT) then
            crec.request_prefix = nil
            return
        end
        local data = crec.request_prefix.data or ""
        local boundary = data:find("\r\n\r\n", 1, true)
        crec.request_end = crec.request_start + (boundary and boundary + 3 or #data)
        if boundary or #data >= RESPONSE_LIMIT then crec.request_prefix = nil end
    end
end

local function native_failure(desync, crec)
    -- Old engines may still send RST inside standard_failure_detector. Clear
    -- reset in this call; the new dispatcher uses the original arg only after
    -- accepting the result. Never run the broad cross-domain redirect heuristic.
    local copy, arg = {}, {}
    for k, v in pairs(desync) do copy[k] = v end
    for k, v in pairs(desync.arg) do arg[k] = v end
    arg.reset, arg.no_http_redirect = nil, true
    copy.arg = arg
    return standard_failure_detector(copy, crec)
end

local function http_response(desync, crec, state)
    local data = state.data or ""
    local boundary = data:find("\r\n\r\n", 1, true)
    if not boundary then
        if #data >= RESPONSE_LIMIT then return false, "neutral" end
        return false, "pending"
    end
    local packet = { outgoing = false, l7payload = "http_reply", track = desync.track, dis = { payload = data } }
    local class = z2k_classify_http_reply(packet)
    if class == "hard_fail" then return true end
    if class == "positive" then return false, "success" end
    local code = tonumber(data:match("^HTTP/1%.[01]%s+(%d%d%d)%s"))
    if not code or code < 400 or code >= 600 then return false, "neutral" end
    local header = data:sub(1, boundary + 1):lower()
    local length = tonumber(header:match("\r\ncontent%-length:%s*(%d+)%s*\r\n"))
    if #data >= RESPONSE_LIMIT or (length and #data - boundary - 3 >= length)
        or header:find("\r\ncontent%-encoding:", 1, false) then
        return false, "neutral"
    end
    -- No length (or chunked): inspect only the bounded prefix, until EOF/cap.
    return false, "pending"
end

local function tls_response(crec, state)
    local data, offset = state.data or "", 1
    if #data - offset + 1 >= 5 then
        local record = data:sub(offset)
        local len = record_length(record)
        if not len or len == 0 or len > 18432 then return false, "neutral" end
        local kind = record:byte(1)
        if kind == 22 then
            if #record < 9 then return false, "pending" end
            local handshake_len = record:byte(7) * 65536 + record:byte(8) * 256 + record:byte(9)
            if record:byte(6) == 2 and len >= 4 and handshake_len >= 38 then
                crec.server_hello = true
                crec.response_prefix = nil
                return false -- only normal byte-progress success from here on
            end
            return false, "neutral"
        elseif kind == 21 then
            if len ~= 2 then return false, "neutral" end
            if #record < 7 then return false, "pending" end
            if record:byte(6) == 2 and record:byte(7) ~= 0 then
                DLOG("z2k_fail_tls_alert: plaintext fatal alert " .. record:byte(7))
                return true
            end
            return false, "neutral"
        elseif kind == 20 or kind == 23 then
            -- Cannot interpret protected records as plaintext alerts, including
            -- TLS 1.2 abbreviated handshakes. No guessed ciphertext severity.
            return false, "neutral"
        else
            return false, "neutral"
        end
    end
    return false, "pending"
end

function z2k_fail_tls_alert(desync, crec)
    if not crec or not desync.dis or not desync.dis.tcp then return false end
    local p, flags = desync.dis.payload or "", desync.dis.tcp.th_flags
    if desync.outgoing then
        first_request(desync, crec)
        local seq = pos_get(desync, 's')
        if crec.request_end and not crec.server_hello and not crec.http_started
            and seq >= crec.request_start and seq < crec.request_end then
            return native_failure(desync, crec)
        end
        return false
    end
    -- RST is a transport failure within the native window, regardless of TTL.
    if bitand(flags, TH_RST) ~= 0 then return native_failure(desync, crec) end
    if crec.server_hello then return false end
    if #p == 0 then
        if bitand(flags, TH_FIN) ~= 0 and crec.response_prefix then return false, "neutral" end
        return false
    end
    local http = crec.request_kind == "http_req" or desync.arg.key == "http_rkn" or desync.l7payload == "http_reply"
    crec.http_started = http or nil
    crec.response_prefix = crec.response_prefix or {}
    local state = crec.response_prefix
    if not prefix_add(state, pos_get(desync, 's'), p, RESPONSE_LIMIT) then
        crec.response_prefix = nil
        return false, "neutral"
    end
    local failed, outcome
    if http then failed, outcome = http_response(desync, crec, state)
    else failed, outcome = tls_response(crec, state) end
    if failed or outcome == "neutral" or outcome == "success" then crec.response_prefix = nil end
    return failed, outcome
end
