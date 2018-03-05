local ssl = require "ngx.ssl"
local ocsp = require "ngx.ocsp"
local string = require "string"
local open = io.open
local url = require "resty.url"
local http_simple = require "resty.http.simple"
local resolver = require "resty.dns.resolver"

local function read_file(path)
    local file = open(path, "rb")
    if not file then return nil end
    local content = file:read "*a"
    file:close()
    return content
end

-- region Load cert
local ssl_server_name = ssl.server_name()
local certificate_file = "/srv/www/" .. ssl_server_name .. "/current/ssl/fullchain.pem"
local private_key_file = "/srv/www/" .. ssl_server_name .. "/current/ssl/privatekey.pem"

if ssl_server_name == nil then
    ngx.log(ngx.ERR, "No SNI server name sent.")
    return ngx.exit(ngx.ERROR)
end

if not string.match(ssl_server_name, "^[a-zA-Z0-9\\-_\\.]+$") then
    ngx.log(ngx.ERR, "Invalid SNI host name", ssl_server_name)
    return ngx.exit(ngx.ERROR)
end

local pem_cert_chain = read_file(certificate_file)
if not pem_cert_chain then
    ngx.log(ngx.ERR, "failed to load certificate chain from file " .. certificate_file)
    return ngx.exit(ngx.ERROR)
end

local cert_chain, err = ssl.parse_pem_cert(pem_cert_chain)
if not cert_chain then
    ngx.log(ngx.ERR, "failed to parse certificate chain: ", err)
    return ngx.exit(ngx.ERROR)
end

local pem_priv_key = read_file(private_key_file)
if not pem_priv_key then
    ngx.log(ngx.ERR, "failed to load private key from file " .. private_key_file)
    return ngx.exit(ngx.ERROR)
end

local priv_key, err = ssl.parse_pem_priv_key(pem_priv_key)
if not priv_key then
    ngx.log(ngx.ERR, "failed to parse private key: ", err)
    return ngx.exit(ngx.ERROR)
end
-- endregion

-- region Set certs
local ok, err = ssl.clear_certs()
if not ok then
    ngx.log(ngx.ERR, "failed to clear existing (fallback) certificates")
    return ngx.exit(ngx.ERROR)
end

local ok, err = ssl.set_cert(cert_chain)
if not ok then
    ngx.log(ngx.ERR, "failed to set PEM cert: ", err)
    return ngx.exit(ngx.ERROR)
end

local ok, err = ssl.set_priv_key(priv_key)
if not ok then
    ngx.log(ngx.ERR, "failed to set PEM key: ", err)
    return ngx.exit(ngx.ERROR)
end
-- endregion

-- region OSCP
local der_cert_chain, err = ssl.cert_pem_to_der(pem_cert_chain)
if not der_cert_chain then
    ngx.log(ngx.WARN, "failed to convert certificate chain ",
            "from PEM to DER: ", err)
    return
end

local ocsp_url, err = ocsp.get_ocsp_responder_from_der_chain(der_cert_chain)
if not ocsp_url then
    ngx.log(ngx.WARN, "failed to get OCSP responder: ", err)
    return
end

local ocsp_url_parsed = url.parse(ocsp_url)

local ocsp_req, err = ocsp.create_ocsp_request(der_cert_chain)
if not ocsp_req then
    ngx.log(ngx.WARN, "failed to create OCSP request: ", err)
    return
end

local r, err = resolver:new{
    nameservers = {"8.8.8.8", "8.8.4.4"},
    retrans = 5,  -- 5 retransmissions on receive timeout
    timeout = 2000,  -- 2 sec
}
if not r then
    ngx.log(ngx.WARN, "failed to instantiate resolver: ", err)
    return
end

local answers, err = r:query(ocsp_url_parsed.host)
if not answers then
    ngx.log(ngx.WARN, "failed to query: ", err)
    return
end

local found_res
for i,answer in ipairs(answers) do
    if answer.address then
        local res, err = http_simple.request(answer.address, ocsp_url_parsed.port or (ocsp_url_parsed.scheme == "https" and 443 or 80), {
            path = (ocsp_url_parsed.path and ocsp_url_parsed.path or "/") ..
                    (ocsp_url_parsed.params and (";" .. ocsp_url_parsed.params) or "") ..
                    (ocsp_url_parsed.query and ("?" .. ocsp_url_parsed.query) or ""),
            headers = { Host = ocsp_url_parsed.host, ["Content-Type"] = "application/ocsp-request" },
            timeout = 10000,  -- 10 sec
            method = "POST",
            body = ocsp_req,
            maxsize = 102400,  -- 100KB
        })
        if res then
            found_res = res
            break
        else
            ngx.log(ngx.WARN, "OCSP responder query failed: ", err)
        end
    end
end
if not found_res then
    ngx.log(ngx.WARN, "No OCSP responder provided a response.")
    return
end

local http_status = found_res.status

if http_status ~= 200 then
    ngx.log(ngx.WARN, "OCSP responder returns bad HTTP status code ", http_status)
    return
end

local ocsp_resp = found_res.body

if ocsp_resp and #ocsp_resp > 0 then
    local ok, err = ocsp.validate_ocsp_response(ocsp_resp, der_cert_chain)
    if not ok then
        ngx.log(ngx.WARN, "failed to validate OCSP response: ", err)
        return
    end

    -- set the OCSP stapling
    ok, err = ocsp.set_ocsp_status_resp(ocsp_resp)
    if not ok then
        ngx.log(ngx.WARN, "failed to set ocsp status resp: ", err)
        return
    end
end
-- endregion
