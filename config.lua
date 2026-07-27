return {
    prefix = 'cc',

    -- Shared secret for Discord bridge HTTP auth (must match discord/config.json bridgeSecret)
    -- Generate with: openssl rand -hex 32
    bridgeSecret = 'CHANGE_ME',

    -- Discord webhook for admin action logging (set to nil to disable)
    adminWebhook = nil,
    -- adminWebhook = 'https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN',

    -- Log all admin actions to console (set to true for debugging)
    logAllActions = false,

    -- Maximum ban duration in seconds (default: 1 year)
    MAX_BAN_DURATION = 31536000,

    perms = {
        list = 'mod',
        kick = 'mod',
        ban = 'admin',
        unban = 'admin',
        baninfo = 'admin',
        undo = 'mod',
        announce = 'admin',
        heal = 'mod',
        kill = 'mod',
        revive = 'mod',
        freeze = 'mod',
        goto_cmd = 'mod',
        bring = 'mod',
        car = 'admin',
        fix = 'admin',
        dv = 'admin',
        giveitem = 'admin',
        setjob = 'admin',
        setgang = 'admin',
        givecash = 'admin',
        givebank = 'admin',
        armor = 'admin',
        setmodel = 'admin',
        noclip = 'mod',
        tp = 'mod',
        godmode = 'admin',
        visible = 'admin',
        hide = 'mod',
        bucket = 'mod',
    },
}
