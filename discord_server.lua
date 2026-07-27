local config = require 'config'

local allowedPaths = { ['/discord'] = true }

SetHttpHandler(function(req, res)
    local path = req.path:match('^/([^?]*)')
    if not allowedPaths[path] then
        res.writeHead(404, { ['Content-Type'] = 'application/json' })
        res.send(json.encode({ error = 'Not found' }))
        return
    end

    if req.method ~= 'GET' then
        res.writeHead(405, { ['Content-Type'] = 'application/json' })
        res.send(json.encode({ error = 'Method not allowed' }))
        return
    end

    local ip = req.address
    if ip ~= '127.0.0.1' and ip ~= '::1' then
        res.writeHead(403, { ['Content-Type'] = 'application/json' })
        res.send(json.encode({ error = 'Forbidden' }))
        return
    end

    local bodyParam = req.path:match('body=([^&]+)')
    if not bodyParam then
        res.writeHead(400, { ['Content-Type'] = 'application/json' })
        res.send(json.encode({ error = 'Missing body parameter' }))
        return
    end

    local decoded = bodyParam:gsub('%%(%x%x)', function(h)
        return string.char(tonumber(h, 16))
    end)

    local ok, data = pcall(json.decode, decoded)
    if not ok or type(data) ~= 'table' or not data.command then
        res.writeHead(400, { ['Content-Type'] = 'application/json' })
        res.send(json.encode({ error = 'Invalid request body' }))
        return
    end

    -- Validate bridge secret to prevent other resources from calling this endpoint
    if not data.secret or data.secret ~= config.bridgeSecret then
        res.writeHead(403, { ['Content-Type'] = 'application/json' })
        res.send(json.encode({ error = 'Invalid secret' }))
        return
    end

    local command = tostring(data.command)
    if #command > 512 then
        res.writeHead(400, { ['Content-Type'] = 'application/json' })
        res.send(json.encode({ error = 'Command too long' }))
        return
    end

    print(('[cuppa_admin] Discord command from %s: %s'):format(data.userId or '?', command))

    local output = executeCommand(command)

    res.writeHead(200, { ['Content-Type'] = 'application/json' })
    res.send(json.encode({ output = output }))
end)
