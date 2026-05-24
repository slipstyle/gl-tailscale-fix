-- gl-tailscale-fix: inject script tag into GL admin SPA HTML
-- Copyright (c) 2026 RemoteToHome Consulting (https://remotetohome.io)
-- https://github.com/RemoteToHome-io/gl-tailscale-fix
if ngx.var.uri == "/gl_home.html" or ngx.var.uri == "/" then
    local chunk = ngx.arg[1]
    if chunk and chunk:find("</head>") then
        -- Version-stamped URL forces browsers to refetch ts-fix.js after a
        -- plugin upgrade (otherwise the cached old JS keeps showing the old
        -- version badge in the admin UI until a hard refresh). {{VERSION}}
        -- is substituted by pkg/build.sh at build time.
        ngx.arg[1] = chunk:gsub("</head>",
            '<script defer src="/ts-fix/ts-fix.js?v={{VERSION}}"></script></head>', 1)
    end
end
