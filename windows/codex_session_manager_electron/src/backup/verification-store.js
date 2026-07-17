'use strict';

const fsp = require('node:fs/promises');

const { replaceFileDurably } = require('./durable-write');

const VERIFICATION_VERSION = 1;
const VERIFICATION_ALGORITHM = 'sha256-chunks-v1';
const DEFAULT_VERIFICATION_CHUNK_SIZE = 4 * 1024 * 1024;

function emptyVerificationDocument(chunkSize = DEFAULT_VERIFICATION_CHUNK_SIZE) {
  return {
    version: VERIFICATION_VERSION,
    algorithm: VERIFICATION_ALGORITHM,
    chunkSize,
    sessions: {},
  };
}

function validateDocument(document) {
  if (!document
    || document.version !== VERIFICATION_VERSION
    || document.algorithm !== VERIFICATION_ALGORITHM
    || !Number.isSafeInteger(document.chunkSize)
    || document.chunkSize !== DEFAULT_VERIFICATION_CHUNK_SIZE
    || !document.sessions
    || typeof document.sessions !== 'object'
    || Array.isArray(document.sessions)) {
    throw new Error('Invalid NAS backup verification document.');
  }
  return document;
}

async function loadVerification(filePath) {
  try {
    return validateDocument(JSON.parse(await fsp.readFile(filePath, 'utf8')));
  } catch (error) {
    if (error.code === 'ENOENT') return emptyVerificationDocument();
    throw error;
  }
}

async function saveVerification(filePath, document) {
  validateDocument(document);
  await replaceFileDurably(filePath, `${JSON.stringify(document, null, 2)}\n`);
}

module.exports = {
  DEFAULT_VERIFICATION_CHUNK_SIZE,
  VERIFICATION_ALGORITHM,
  VERIFICATION_VERSION,
  emptyVerificationDocument,
  loadVerification,
  saveVerification,
};
