import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MODULE_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const CONFIG_DIRECTORY = path.resolve(MODULE_DIRECTORY, '..', '..', 'Config');
const STABLE_CONFIG_PATH = path.join(CONFIG_DIRECTORY, 'UpdateServer.json');
const TESTING_CONFIG_PATH = path.join(CONFIG_DIRECTORY, 'UpdateServer.testing.json');

export function parseUpdateServerConfig(value, scope = 'stable') {
  if (!['stable', 'testing'].includes(scope)) {
    throw new Error('update server scope must be stable or testing');
  }
  if (!value || typeof value !== 'object' || typeof value.releaseBaseURL !== 'string') {
    throw new Error('releaseBaseURL must be a string');
  }
  const raw = value.releaseBaseURL;
  let url;
  try {
    url = new URL(raw);
  } catch {
    throw new Error('releaseBaseURL must be an absolute URL');
  }
  const expectedPath = `/codex-session-keeper/${scope}/`;
  if (!['http:', 'https:'].includes(url.protocol)
      || url.username || url.password || url.search || url.hash
      || url.pathname !== expectedPath
      || url.href !== raw) {
    throw new Error(`releaseBaseURL must be a canonical HTTP(S) ${scope}-root URL`);
  }
  return Object.freeze({
    scope,
    releaseBaseURL: url.href,
    windowsFeedURL: new URL('windows/', url).href,
    macDownloadPrefix: new URL('macos/', url).href,
    macAppcastURL: new URL('macos/appcast.xml', url).href,
  });
}

export const UPDATE_SERVERS = Object.freeze({
  stable: parseUpdateServerConfig(
    JSON.parse(readFileSync(STABLE_CONFIG_PATH, 'utf8')),
    'stable',
  ),
  testing: parseUpdateServerConfig(
    JSON.parse(readFileSync(TESTING_CONFIG_PATH, 'utf8')),
    'testing',
  ),
});

export const UPDATE_SERVER = UPDATE_SERVERS.stable;

export function updateServerForScope(scope) {
  const server = UPDATE_SERVERS[scope];
  if (!server) {
    throw new Error('update server scope must be stable or testing');
  }
  return server;
}
