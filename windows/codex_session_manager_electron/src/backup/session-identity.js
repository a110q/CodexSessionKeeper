const path = require('node:path').win32;

const uuidPattern = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;

function sessionIdFromPath(filePath) {
  const basename = path.basename(String(filePath ?? ''));
  const extension = path.extname(basename);

  if (extension.toLowerCase() !== '.jsonl') {
    return null;
  }

  const stem = basename.slice(0, -extension.length);
  if (!stem) {
    return null;
  }

  const uuid = stem.match(uuidPattern);
  return uuid ? uuid[0].toLowerCase() : stem;
}

function textFromContent(content) {
  if (typeof content === 'string') {
    return content;
  }

  if (!Array.isArray(content)) {
    return null;
  }

  const parts = [];
  for (const part of content) {
    if (typeof part === 'string') {
      parts.push(part);
    } else if (part && typeof part.text === 'string') {
      parts.push(part.text);
    }
  }

  return parts.join(' ');
}

function textFromPayload(payload) {
  if (!payload || typeof payload !== 'object') {
    return null;
  }

  if (typeof payload.message === 'string' && normalizeTitle(payload.message)) {
    return payload.message;
  }

  return textFromContent(payload.content);
}

function userTextFromRecord(record) {
  if (!record || typeof record !== 'object') {
    return null;
  }

  if (record.role === 'user') {
    return textFromContent(record.content);
  }

  if (record.item && record.item.role === 'user') {
    return textFromContent(record.item.content);
  }

  if (record.type === 'user_message') {
    return textFromPayload(record.payload || record);
  }

  if (
    record.payload
    && typeof record.payload === 'object'
    && (record.payload.type === 'user_message' || record.payload.role === 'user')
  ) {
    return textFromPayload(record.payload);
  }

  return null;
}

function normalizeTitle(text) {
  if (typeof text !== 'string') {
    return null;
  }

  const title = text.replace(/\s+/g, ' ').trim();
  if (!title) {
    return null;
  }

  return title.length > 80 ? title.slice(0, 80) : title;
}

function titleFromJsonLine(line) {
  let record;
  try {
    record = JSON.parse(line);
  } catch {
    return null;
  }

  return normalizeTitle(userTextFromRecord(record));
}

module.exports = {
  sessionIdFromPath,
  titleFromJsonLine,
};
