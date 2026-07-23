const { Client, GatewayIntentBits, EmbedBuilder } = require('discord.js');
const { Rcon } = require('rcon-client');
const fs = require('fs');
const path = require('path');

// Load config
const configPath = path.join(__dirname, 'config.json');
if (!fs.existsSync(configPath)) {
    console.error('config.json not found. Copy config.json and fill in your settings.');
    process.exit(1);
}
const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));

// Validate config
if (!config.discord.token || config.discord.token === 'YOUR_BOT_TOKEN') {
    console.error('Please set your Discord bot token in config.json');
    process.exit(1);
}
if (!config.fivem.rconPassword || config.fivem.rconPassword === 'YOUR_RCON_PASSWORD') {
    console.error('Please set your RCON password in config.json');
    process.exit(1);
}

// Discord client
const client = new Client({
    intents: [
        GatewayIntentBits.Guilds,
        GatewayIntentBits.GuildMessages,
        GatewayIntentBits.MessageContent,
    ]
});

// Rate limiting
const lastCommand = new Map();

// Strip ANSI color codes from RCON output
function stripAnsi(str) {
    return str.replace(/\x1B\[[0-9;]*[mK]/g, '').replace(/\^[0-9]/g, '').trim();
}

// Check if user has required role (supports both IDs and names)
function hasPermission(member) {
    if (!config.discord.adminRoles || config.discord.adminRoles.length === 0) return true;
    return member.roles.cache.some(role =>
        config.discord.adminRoles.includes(role.id) ||
        config.discord.adminRoles.includes(role.name)
    );
}

// Rate limit check
function isRateLimited(userId) {
    const now = Date.now();
    const last = lastCommand.get(userId) || 0;
    if (now - last < config.discord.rateLimitMs) return true;
    lastCommand.set(userId, now);
    return false;
}

// Execute RCON command
async function executeRcon(command) {
    let rcon;
    try {
        rcon = await Rcon.connect({
            host: config.fivem.host,
            port: config.fivem.port,
            password: config.fivem.rconPassword,
            timeout: 5000,
        });
        const response = await rcon.send(command);
        await rcon.end();
        return response;
    } catch (error) {
        if (rcon) try { await rcon.end(); } catch {}
        throw error;
    }
}

// Log to audit channel
async function auditLog(message, command, result) {
    if (!config.discord.auditChannelId) return;
    try {
        const channel = await client.channels.fetch(config.discord.auditChannelId);
        if (!channel) return;
        const embed = new EmbedBuilder()
            .setColor(0x3498db)
            .setTitle('Admin Command')
            .addFields(
                { name: 'Admin', value: `${message.author.tag} (${message.author.id})`, inline: true },
                { name: 'Command', value: `\`${command}\``, inline: false },
                { name: 'Result', value: stripAnsi(result || 'No output') || 'No output', inline: false },
            )
            .setTimestamp();
        await channel.send({ embeds: [embed] });
    } catch (error) {
        console.error('Audit log failed:', error.message);
    }
}

// Handle status command via HTTP API
async function handleStatus(message) {
    try {
        const baseUrl = `http://${config.fivem.host}:${config.fivem.port}`;

        const [playersRes, infoRes] = await Promise.all([
            fetch(`${baseUrl}/players.json`),
            fetch(`${baseUrl}/info.json`),
        ]);

        if (!playersRes.ok || !infoRes.ok) {
            return message.reply('Could not fetch server info. Is the server running?');
        }

        const players = await playersRes.json();
        const info = await infoRes.json();

        const embed = new EmbedBuilder()
            .setColor(0x2ecc71)
            .setTitle('Server Status')
            .addFields(
                { name: 'Hostname', value: info.hostname || 'Unknown', inline: true },
                { name: 'Players', value: `${players.length}/${info.maxclients || '?'}`, inline: true },
                { name: 'Version', value: String(info.version || 'Unknown'), inline: true },
            )
            .setTimestamp();

        if (players.length > 0) {
            const playerList = players.map(p =>
                `**${p.id}** | ${p.name || 'Unknown'} | Ping: ${p.ping || '?'}`
            ).join('\n');
            embed.addFields({ name: `Online Players (${players.length})`, value: playerList || 'None' });
        } else {
            embed.addFields({ name: 'Online Players', value: 'No players online' });
        }

        await message.reply({ embeds: [embed] });
    } catch (error) {
        message.reply(`Error fetching server status: \`${error.message}\``);
    }
}

// Format RCON output for Discord
function formatOutput(output) {
    const clean = stripAnsi(output);
    if (!clean) return 'Command executed (no output)';
    // Use code block for multi-line output
    if (clean.includes('\n')) {
        return '```\n' + clean + '\n```';
    }
    return clean;
}

// Bot ready
client.once('clientReady', () => {
    console.log(`Logged in as ${client.user.tag}`);
    console.log(`Prefix: ${config.discord.prefix}`);
    console.log(`Admin Channel: ${config.discord.adminChannelId || 'any'}`);
    console.log(`Admin Roles: ${config.discord.adminRoles.join(', ') || 'all'}`);
    console.log(`FiveM: ${config.fivem.host}:${config.fivem.port}`);
});

// Message handler
client.on('messageCreate', async (message) => {
    try {
        // Ignore bots and DMs
        if (message.author.bot) return;
        if (!message.guild) return;

        // Check prefix
        const prefix = config.discord.prefix;
        if (!message.content.startsWith(prefix)) return;

        // Check channel (if configured)
        if (config.discord.adminChannelId && message.channel.id !== config.discord.adminChannelId) return;

        // Check permissions
        if (!hasPermission(message.member)) {
            return message.reply('You do not have permission to use this command.');
        }

        // Rate limiting
        if (isRateLimited(message.author.id)) {
            return message.reply('Please wait before using another command.');
        }

        // Parse command
        const content = message.content.slice(prefix.length).trim();
        if (!content) {
            // No command — show player list
            return handleStatus(message);
        }

        const args = content.split(/\s+/);
        const cmd = args[0].toLowerCase();

        // Handle status
        if (cmd === 'status') {
            return handleStatus(message);
        }

        // Handle help
        if (cmd === 'help') {
            const helpText = [
                '`!cc` — Server status / player list',
                '`!cc help` — Show this help',
                '`!cc kick <id> [reason]` — Kick a player',
                '`!cc ban <id> [reason] [dur]` — Ban a player (dur: 24h/7d/1m/1y)',
                '`!cc unban <banid>` — Unban by ban ID',
                '`!cc heal [id]` — Heal a player',
                '`!cc kill [id]` — Kill a player',
                '`!cc revive [id]` — Revive a player',
                '`!cc freeze [id]` — Freeze a player',
                '`!cc unfreeze [id]` — Unfreeze a player',
                '`!cc tp <id> [id]` — Teleport player',
                '`!cc godmode [id]` — Toggle godmode',
                '`!cc visible [id]` — Toggle visibility',
                '`!cc vehicle <model> [id]` — Spawn vehicle',
                '`!cc fix [id]` — Fix vehicle',
                '`!cc dv [id] [radius]` — Delete vehicle(s)',
                '`!cc giveitem <id> <item> [n]` — Give items',
                '`!cc setjob <id> <job> [grade]` — Set job',
                '`!cc setgang <id> <gang> [grade]` — Set gang',
                '`!cc givecash <id> <amount>` — Give cash',
                '`!cc givebank <id> <amount>` — Give bank',
                '`!cc armor <id> [amount]` — Set armor',
                '`!cc setmodel <model> [id]` — Set model',
                '`!cc noclip [id]` — Toggle noclip',
            ].join('\n');
            return message.reply(helpText);
        }

        // Execute command via RCON
        const rconCommand = content;
        await message.deferReply();

        try {
            const response = await executeRcon(rconCommand);
            const formatted = formatOutput(response);
            await message.editReply(formatted);
            await auditLog(message, rconCommand, response);
        } catch (error) {
            await message.editReply(`Error executing command: \`${error.message}\``);
        }

    } catch (error) {
        console.error('Message handler error:', error);
        try {
            if (message.replied) return;
            if (message.deferred) {
                await message.editReply('An unexpected error occurred.');
            } else {
                await message.reply('An unexpected error occurred.');
            }
        } catch {}
    }
});

// Error handling
client.on('error', error => {
    console.error('Discord client error:', error.message);
});

// Reconnect on disconnect
client.on('disconnect', () => {
    console.log('Disconnected from Discord. Reconnecting...');
});

// Login
console.log('Starting cuppa_admin Discord bot...');
client.login(config.discord.token).catch(error => {
    console.error('Failed to login:', error.message);
    process.exit(1);
});
