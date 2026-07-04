const assert = require('node:assert/strict');
const test = require('node:test');

const { sessionIdFromPath, titleFromJsonLine } = require('../../src/backup/session-identity');

test('sessionIdFromPath uses the jsonl filename stem', () => {
  assert.equal(sessionIdFromPath('C:\\Users\\Ada\\.codex\\sessions\\plain-session.jsonl'), 'plain-session');
});

test('sessionIdFromPath returns null for non-jsonl paths', () => {
  assert.equal(sessionIdFromPath('C:\\Users\\Ada\\.codex\\sessions\\plain-session.txt'), null);
});

test('sessionIdFromPath prefers an embedded UUID and lowercases it', () => {
  assert.equal(
    sessionIdFromPath('C:\\Users\\Ada\\.codex\\sessions\\prefix-A56C9D44-94F7-46D4-A53F-BCB1D7D2776C-suffix.JSONL'),
    'a56c9d44-94f7-46d4-a53f-bcb1d7d2776c',
  );
});

test('sessionIdFromPath returns null for an empty jsonl stem', () => {
  assert.equal(sessionIdFromPath('C:\\Users\\Ada\\.codex\\sessions\\.jsonl'), null);
});

test('titleFromJsonLine reads top-level user content', () => {
  assert.equal(
    titleFromJsonLine(JSON.stringify({ role: 'user', content: '  Hello from   Codex  ' })),
    'Hello from Codex',
  );
});

test('titleFromJsonLine reads message content arrays', () => {
  assert.equal(
    titleFromJsonLine(JSON.stringify({
      type: 'message',
      role: 'user',
      content: [{ text: 'First' }, { text: 'second' }],
    })),
    'First second',
  );
});

test('titleFromJsonLine reads nested item user content arrays', () => {
  assert.equal(
    titleFromJsonLine(JSON.stringify({
      item: {
        role: 'user',
        content: [{ text: 'Nested' }, { text: 'message' }],
      },
    })),
    'Nested message',
  );
});

test('titleFromJsonLine reads Codex payload message and content shapes', () => {
  assert.equal(
    titleFromJsonLine(JSON.stringify({
      type: 'user_message',
      payload: { message: 'Payload message' },
    })),
    'Payload message',
  );
  assert.equal(
    titleFromJsonLine(JSON.stringify({
      payload: {
        type: 'user_message',
        content: [{ text: 'Payload' }, { text: 'content' }],
      },
    })),
    'Payload content',
  );
  assert.equal(
    titleFromJsonLine(JSON.stringify({
      payload: {
        role: 'user',
        content: [{ text: 'Payload role' }],
      },
    })),
    'Payload role',
  );
});

test('titleFromJsonLine returns null for invalid, assistant, and empty input', () => {
  assert.equal(titleFromJsonLine('{'), null);
  assert.equal(titleFromJsonLine(JSON.stringify({ role: 'assistant', content: 'Nope' })), null);
  assert.equal(titleFromJsonLine(JSON.stringify({ role: 'user', content: '   ' })), null);
});

test('titleFromJsonLine collapses multipart whitespace and truncates at 80 chars', () => {
  const title = titleFromJsonLine(JSON.stringify({
    role: 'user',
    content: [
      { text: 'Line one\n\nline two' },
      { text: ' '.repeat(5) },
      { text: 'x'.repeat(100) },
    ],
  }));

  assert.equal(title, 'Line one line two ' + 'x'.repeat(62));
  assert.equal(title.length, 80);
});
