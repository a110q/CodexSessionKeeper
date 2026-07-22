import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MODULE_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const CONFIG_PATH = path.resolve(MODULE_DIRECTORY, '..', '..', 'Config', 'UpdateServer.json');

export function parseUpdateServerConfig(value) {
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
  if (!['http:', 'https:'].includes(url.protocol)
      || url.username || url.password || url.search || url.hash
      || url.pathname !== '/codex-session-keeper/stable/'
      || url.href !== raw) {
    throw new Error('releaseBaseURL must be a canonical HTTP(S) stable-root URL');
  }
  return Object.freeze({
    releaseBaseURL: url.href,
    windowsFeedURL: new URL('windows/', url).href,
    macDownloadPrefix: new URL('macos/', url).href,
    macAppcastURL: new URL('macos/appcast.xml', url).href,
  });
}

export const UPDATE_SERVER = parseUpdateServerConfig(
  JSON.parse(readFileSync(CONFIG_PATH, 'utf8')),
);
