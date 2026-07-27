const { Client, GatewayIntentBits, EmbedBuilder } = require('discord.js');
const fs = require('fs');
const path = require('path');

const config = JSON.parse(fs.readFileSync(path.join(__dirname, 'config.json'), 'utf8'));

if (!config.token || config.token === 'YOUR_BOT_TOKEN') {
    console.error('Set your bot token in config.json');
    process.exit(1);
}

const client = new Client({
    intents: [
        GatewayIntentBits.Guilds,
        GatewayIntentBits.GuildMessages,
        GatewayIntentBits.MessageContent,
    ]
});

const lastCommand = new Map();

function hasPermission(member) {
    if (!config.adminRoles || config.adminRoles.length === 0) return true;
    return member.roles.cache.some(role => config.adminRoles.includes(role.id));
}

function isRateLimited(userId) {
    const now = Date.now();
    const last = lastCommand.get(userId) || 0;
    if (now - last < (config.rateLimitMs || 1000)) return true;
    lastCommand.set(userId, now);
    return false;
}

function stripAnsi(str) {
    return str.replace(/\x1B\[[0-9;]*[mK]/g, '').replace(/\^[0-9]/g, '').trim();
}

async function sendToFiveM(command, userId) {
    const body = JSON.stringify({ command, userId, secret: config.bridgeSecret });
    const url = `http://127.0.0.1:${config.fivemPort || 30120}/cuppa_admin/discord?body=${encodeURIComponent(body)}`;
    const res = await fetch(url);
    const data = await res.json();
    return data.output || 'Command executed (no output)';
}

async function handleStatus(message) {
    try {
        const port = config.fivemPort || 30120;
        const [playersRes, infoRes] = await Promise.all([
            fetch(`http://127.0.0.1:${port}/players.json`),
            fetch(`http://127.0.0.1:${port}/info.json`),
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
        message.reply(`Error: \`${error.message}\``);
    }
}

function showHelp() {
    return [
        '`!cc` — Server status / player list',
        '`!cc stats` — List all online players',
        '`!cc help` — Show this help',
        '`!cc announce <msg>` — Server-wide announcement',
        '`!cc kick [reason] <id>` — Kick a player',
        '`!cc ban [reason] [dur] <id>` — Ban (dur: 24h/7d/1m/1y)',
        '`!cc unban <banid>` — Unban by ban ID',
        '`!cc baninfo <banid>` — Look up ban details',
        '`!cc undo <id>` — Reverse last admin action',
        '`!cc heal <id>` — Heal a player',
        '`!cc kill [id]` — Kill a player',
        '`!cc revive <id>` — Revive a player',
        '`!cc freeze <id|all>` — Toggle freeze on a player (or all)',
        '`!cc tp <id> [id]` — Teleport player',
        '`!cc godmode [id]` — Toggle godmode',
        '`!cc visible [id]` — Toggle visibility',
        '`!cc hide <id>` — Hide from everyone except <id>',
        '`!cc show` — Restore visibility',
        '`!cc car <model> [id]` — Spawn vehicle',
        '`!cc fix [id]` — Fix vehicle',
        '`!cc dv [radius] [id]` — Delete vehicle(s)',
        '`!cc giveitem <item> [n] <id>` — Give items',
        '`!cc setjob <job> [grade] <id>` — Set job',
        '`!cc setgang <gang> [grade] <id>` — Set gang',
        '`!cc givecash <amount> <id>` — Give cash',
        '`!cc givebank <amount> <id>` — Give bank',
        '`!cc armor [amount] <id>` — Set armor',
        '`!cc setmodel <model> [id]` — Set model',
        '`!cc noclip [id]` — Toggle noclip',
        '`!cc bucket` — Bucket status / create',
        '`!cc bucket <id>` — Add player to bucket',
        '`!cc bucket -<id>` — Remove from bucket',
        '`!cc bucket destroy [id]` — Dissolve bucket',
        '`!cc bucket wipe` — Destroy all buckets',
    ].join('\n');
}

client.once('clientReady', () => {
    console.log(`Logged in as ${client.user.tag}`);
    console.log(`Prefix: ${config.prefix}`);
    console.log(`Channel: ${config.adminChannelId || 'any'}`);
    console.log(`Roles: ${config.adminRoles?.join(', ') || 'all'}`);
});

client.on('messageCreate', async (message) => {
    try {
        if (message.author.bot) return;
        if (!message.guild) return;
        if (!message.content.startsWith(config.prefix)) return;
        if (config.adminChannelId && message.channel.id !== config.adminChannelId) return;
        if (!hasPermission(message.member)) {
            return message.reply('You do not have permission to use this command.');
        }
        if (isRateLimited(message.author.id)) {
            return message.reply('Please wait before using another command.');
        }

        const content = message.content.slice(config.prefix.length).trim();

        if (!content) return handleStatus(message);

        const args = content.split(/\s+/);
        const cmd = args[0].toLowerCase();

        if (cmd === 'status') return handleStatus(message);
        if (cmd === 'help') return message.reply(showHelp());

        await message.deferReply();

        try {
            const output = await sendToFiveM(content, message.author.id);
            const clean = stripAnsi(output);
            if (!clean) {
                await message.editReply('Command executed (no output)');
            } else if (clean.includes('\n')) {
                await message.editReply('```\n' + clean + '\n```');
            } else {
                await message.editReply(clean);
            }
        } catch (error) {
            await message.editReply(`Error: \`${error.message}\``);
        }
    } catch (error) {
        console.error('Message handler error:', error);
        try {
            if (message.deferred) await message.editReply('An unexpected error occurred.');
            else await message.reply('An unexpected error occurred.');
        } catch {}
    }
});

client.on('error', error => console.error('Discord error:', error.message));
client.on('disconnect', () => console.log('Disconnected. Reconnecting...'));

console.log('Starting cuppa_admin Discord bridge...');
client.login(config.token).catch(error => {
    console.error('Failed to login:', error.message);
    process.exit(1);
});
