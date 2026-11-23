import { readdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';

const [configArg, label, title] = process.argv.slice(2);
if (!configArg || !/^[\p{L}\p{N}_-]{1,40}$/u.test(label ?? '') || !title) {
  throw new Error('Usage: node bind-mac-route.mjs <config.json> <label> <exact window title>');
}
const codex = process.env.CODEX_HOME || join(homedir(), '.codex');
const rows = readFileSync(join(codex, 'session_index.jsonl'), 'utf8').trim().split('\n');
const indexed = new Map();
for (const line of rows) {
  try {
    const row = JSON.parse(line);
    if (row.id && row.thread_name) indexed.set(row.id, row.thread_name);
  } catch { /* A live write can leave the last line incomplete. */ }
}
const matches = [...indexed].filter(([, name]) => name === title);
if (matches.length !== 1) {
  throw new Error('Expected one local window with that exact title, found ' + matches.length + '.');
}
const [id] = matches[0];
const exists = readdirSync(join(codex, 'sessions'), { recursive: true }).some(path => path.endsWith('-' + id + '.jsonl'));
if (!exists) throw new Error('The matched window could not be verified in local session storage.');
const configFile = resolve(configArg);
const config = JSON.parse(readFileSync(configFile, 'utf8'));
config.routes = { ...config.routes, [label]: id };
const temp = configFile + '.' + process.pid + '.tmp';
writeFileSync(temp, JSON.stringify(config, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
renameSync(temp, configFile);
console.log('Bound [' + label + '] to ' + title + '.');
