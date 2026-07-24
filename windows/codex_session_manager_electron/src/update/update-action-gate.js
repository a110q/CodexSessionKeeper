const ACTIONS = new Set(['download', 'install']);

async function runConfirmedUpdateAction({
  action,
  version,
  confirm,
  audit,
  perform,
}) {
  if (!ACTIONS.has(action)) throw new TypeError('Unknown update action.');
  if (typeof version !== 'string' || version.length === 0 || version.length > 64) {
    throw new TypeError('Update version is invalid.');
  }
  if (typeof confirm !== 'function' || typeof audit !== 'function' || typeof perform !== 'function') {
    throw new TypeError('Update action requires confirmation, audit, and operation callbacks.');
  }

  await audit({ event: `${action}_confirmation_requested`, version });
  const confirmed = await confirm({ action, version }) === true;
  if (!confirmed) {
    await audit({ event: `${action}_cancelled`, version });
    return { confirmed: false };
  }

  await audit({ event: `${action}_confirmed`, version });
  await audit({ event: `${action}_requested`, version });
  return {
    confirmed: true,
    result: await perform(),
  };
}

module.exports = {
  runConfirmedUpdateAction,
};
