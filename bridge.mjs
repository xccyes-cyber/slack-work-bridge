import { execFile } from 'node:child_process';
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { promisify } from 'node:util';

const exec = promisify(execFile);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const configPath = resolve(process.argv[2] ?? 'bridge.json');
const config = JSON.parse(readFileSync(configPath, 'utf8').replace(/^\uFEFF/, ''));
const slackId = /^[A-Z][A-Z0-9]+$/;
const channelId = /^[CG][A-Z0-9]+$/;
const slackTimestamp = /^\d+\.\d+$/;
const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const routeName = /^[\p{L}\p{N}_-]{1,40}$/u;
function validateRoutes(values) {
  const routes = new Map(Object.entries(values ?? {}));
  if (!routes.size || [...routes].some(([name, id]) => !routeName.test(name) || typeof id !== 'string' || !uuid.test(id))) {
    throw new Error('Invalid route configuration. Add a label and a local Codex session UUID for each target.');
  }
  return routes;
}
function validateRouting(settings) {
  const routes = validateRoutes(settings.routes);
  const channels = new Map(Object.entries(settings.channelRoutes ?? {}));
  const legacy = settings.channel || null;
  if ((legacy && (typeof legacy !== 'string' || !channelId.test(legacy)))
    || [...channels].some(([id, route]) => !channelId.test(id) || !routes.has(route))
    || (!legacy && !channels.size)) {
    throw new Error('Invalid channel routing. Map at least one Slack channel ID to a configured route.');
  }
  return { routes, channels, legacy };
}
function currentRouting() {
  return validateRouting(JSON.parse(readFileSync(configPath, 'utf8').replace(/^\uFEFF/, '')));
}
function routeForChannel(routing, channel, label) {
  const fixedRoute = routing.channels.get(channel);
  if (fixedRoute) return !label || label === fixedRoute ? fixedRoute : null;
  return channel === routing.legacy ? label : null;
}
const targetCount = validateRouting(config).routes.size;
if (![config.team, config.app, config.bot].every(value => typeof value === 'string' && slackId.test(value))
  || !Array.isArray(config.senders) || !config.senders.length || !config.senders.every(id => typeof id === 'string' && slackId.test(id))
  || typeof config.codex !== 'string' || !config.codex) {
  throw new Error('Invalid bridge configuration. Check the Slack IDs, sender allowlist, routes and Codex path.');
}
if (process.argv.includes('--check-config')) process.exit(0);

const directory = dirname(configPath);
mkdirSync(directory, { recursive: true, mode: 0o700 });
const journal = join(directory, 'deliveries.jsonl');
const states = new Map();
function log(stage, details = {}) {
  const line = JSON.stringify({ at: new Date().toISOString(), stage, ...details });
  writeFileSync(join(directory, 'status.json'), line + '\n', { mode: 0o600 });
  console.log(line);
}
function persist(entry) {
  appendFileSync(journal, JSON.stringify(entry) + '\n', { mode: 0o600, flush: true });
  states.set(entry.id, entry);
}
try {
  for (const line of readFileSync(journal, 'utf8').split('\n')) {
    if (line) {
      const entry = JSON.parse(line);
      states.set(entry.id, entry);
    }
  }
} catch (error) {
  if (error.code !== 'ENOENT') throw error;
}
if (states.size) {
  log('journal_loaded', {
    pending: [...states.values()].filter(item => item.state === 'pending').length,
    needsReview: [...states.values()].filter(item => item.state === 'dispatching' || item.state === 'needs_review').length,
  });
}

const allowedSenders = new Set(config.senders);
const escapedBot = new RegExp('^(?:<@' + config.bot + '(?:\\|[^>]+)?>|&lt;@' + config.bot + '(?:\\|[^&]+)?&gt;)\\s*', 'u');
function parseEvent(payload) {
  const event = payload?.event;
  if (payload?.team_id !== config.team || payload.api_app_id !== config.app
    || event?.type !== 'app_mention' || typeof event.channel !== 'string' || !channelId.test(event.channel)
    || !allowedSenders.has(event.user) || event.bot_id || event.subtype
    || typeof event.ts !== 'string' || !slackTimestamp.test(event.ts)
    || typeof event.text !== 'string') return null;

  const text = event.text.replace(/[\u200B-\u200D\uFEFF]/gu, '').trim();
  // Slack already matched the app mention at the API level. Accept only a route and a nonempty task.
  const body = text.replace(escapedBot, '').trim();
  const selection = body.match(/^\[([\p{L}\p{N}_-]{1,40})\]\s*/u);
  const routing = currentRouting();
  const route = routeForChannel(routing, event.channel, selection?.[1]);
  const target = routing.routes.get(route);
  if (!target) return null;
  const task = body.slice(selection?.[0].length ?? 0).trim();
  if (!task || task.length > 4000) return null;
  const replyThread = typeof event.thread_ts === 'string' && slackTimestamp.test(event.thread_ts)
    ? event.thread_ts : event.ts;
  return { id: event.channel + ':' + event.ts, state: 'pending', route, target, sender: event.user, ts: event.ts, replyThread, task };
}

async function readToken() {
  if (config.credential?.kind === 'mac-keychain') {
    const { stdout } = await exec('/usr/bin/security', [
      'find-generic-password', '-a', config.credential.account, '-s', config.credential.service, '-w',
    ], { timeout: 45000 });
    return stdout.trim();
  }
  if (config.credential?.kind === 'windows-dpapi') {
    const script = [
      '$ErrorActionPreference = "Stop"',
      '$value = Get-Content -LiteralPath $env:SLACK_BRIDGE_TOKEN_FILE -Raw',
      '$secret = ConvertTo-SecureString -String $value.Trim()',
      '$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)',
      'try { [Console]::Write([Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)) }',
      'finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }',
    ].join('\n');
    const { stdout } = await exec('powershell.exe', [
      '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64'),
    ], { timeout: 15000, windowsHide: true, env: { ...process.env, SLACK_BRIDGE_TOKEN_FILE: join(directory, 'slack-token.dpapi') } });
    return stdout.trim();
  }
  throw new Error('Unsupported credential store.');
}

function queueArgs(entry) {
  const sourceChannel = entry.id.split(':', 1)[0];
  const replyThread = entry.replyThread ?? entry.ts;
  const prompt = [
    '本机 Slack 接收器已核验来源频道和发送账号。收到后从任务正文直接开始处理，跳过发送人复核。',
    '遵循本会话的项目规则和操作审批设置。若任务本身有关键歧义或需要批准，按正常流程处理。',
    'Slack 来源：channel_id=' + sourceChannel + '，message_ts=' + entry.ts + '，thread_ts=' + replyThread + '。',
    '如果按授权需要把收件确认或任务结果发回 Slack，请用这里的 channel_id 和 thread_ts 回复原派工线程。此目的地适用于当前任务，优先于之前的默认回复频道。',
    '如果工具无法在原线程回复，请把结果留在当前 Work 对话并说明原因。',
    '以下是 Slack 原文：',
    entry.task,
  ].join('\n');
  return ['queue', '--thread', entry.target, '--message', prompt];
}

let dispatching = false;
let stopping = false;
async function drain() {
  if (dispatching || stopping) return;
  dispatching = true;
  try {
    for (const entry of states.values()) {
      if (stopping) break;
      if (entry.state !== 'pending') continue;
      const routing = currentRouting();
      const channel = entry.id.split(':', 1)[0];
      if (routeForChannel(routing, channel, entry.route) !== entry.route || routing.routes.get(entry.route) !== entry.target) {
        persist({ ...entry, state: 'needs_review', reason: 'route_changed' });
        log('needs_review', { id: entry.id, route: entry.route, reason: 'route_changed' });
        continue;
      }
      persist({ ...entry, state: 'dispatching' });
      try {
        await exec(config.codex, queueArgs(entry), { timeout: 30000, windowsHide: true });
      } catch (error) {
        // A timeout or process failure can occur after Codex has accepted the message.
        // Keep the task for review instead of blindly enqueueing a possible duplicate.
        persist({ ...entry, state: 'needs_review', reason: String(error.code ?? error.signal ?? 'unknown') });
        log('needs_review', { id: entry.id, route: entry.route, reason: String(error.code ?? error.signal ?? 'unknown') });
        continue;
      }
      persist({ id: entry.id, state: 'queued', route: entry.route });
      log('queued', { id: entry.id, route: entry.route });
    }
  } finally {
    dispatching = false;
  }
}
function dispatchPending() {
  // Fail closed on local journal errors. Slack retries unacknowledged events.
  drain().catch(() => process.exit(1));
}

let socket;
function handleEnvelope({ data }) {
  let envelope;
  try { envelope = JSON.parse(data); } catch { return; }
  if (envelope.type === 'disconnect') {
    socket.close();
    return;
  }
  let entry;
  try {
    entry = envelope.type === 'events_api' ? parseEvent(envelope.payload) : null;
    if (entry && !states.has(entry.id)) {
      persist(entry);
      log('received', { id: entry.id, route: entry.route });
    }
  } catch {
    log('journal_write_failed', { id: entry?.id });
    socket.close();
    return;
  }
  if (envelope.envelope_id) socket.send(JSON.stringify({ envelope_id: envelope.envelope_id }));
  if (entry) dispatchPending();
}

async function connect(token) {
  const response = await fetch('https://slack.com/api/apps.connections.open', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + token },
    signal: AbortSignal.timeout(15000),
  });
  const result = await response.json();
  if (!response.ok || !result.ok) throw new Error('Slack refused Socket Mode: ' + (result.error || response.status));
  const address = new URL(result.url);
  if (address.protocol !== 'wss:' || !address.hostname.endsWith('.slack.com')) throw new Error('Unrecognized Slack WebSocket endpoint.');
  socket = new WebSocket(address);
  let welcomed = false;
  await new Promise((done, fail) => {
    const timer = setTimeout(() => {
      socket.close();
      fail(new Error('Slack WebSocket did not send hello.'));
    }, 20000);
    socket.addEventListener('message', event => {
      if (!welcomed) {
        let frame;
        try { frame = JSON.parse(event.data); } catch { return; }
        if (frame.type === 'hello') {
          welcomed = true;
          clearTimeout(timer);
          log('connected', { targetCount });
        }
      }
      handleEnvelope(event);
    });
    socket.addEventListener('close', () => {
      clearTimeout(timer);
      done();
    }, { once: true });
    socket.addEventListener('error', () => {
      clearTimeout(timer);
      socket.close();
      fail(new Error('Slack WebSocket connection failed.'));
    }, { once: true });
  });
  return welcomed;
}

function stop() {
  stopping = true;
  socket?.close();
}
process.on('SIGTERM', stop);
process.on('SIGINT', stop);

const token = await readToken().catch(() => { throw new Error('Cannot read the Slack token from the configured credential store.'); });
if (!token.startsWith('xapp-')) throw new Error('Expected a Slack app-level token (xapp).');
dispatchPending();
let backoff = 1000;
while (!stopping) {
  try {
    if (await connect(token)) backoff = 1000;
  } catch (error) {
    log('connection_failed', { reason: error.message });
  }
  if (!stopping) {
    log('reconnecting', { delayMs: backoff });
    await sleep(backoff);
    backoff = Math.min(backoff * 2, 30000);
  }
}
