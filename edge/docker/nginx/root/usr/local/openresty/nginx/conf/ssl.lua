local ssl = require "ngx.ssl"
local ocsp = require "ngx.ocsp"
local string = require "string"
local open = io.open

local function read_file(path)
    local file = open(path, "rb")
    if not file then return nil end
    local content = file:read "*a"
    file:close()
    return content
end

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
