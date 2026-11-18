const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const workflow = JSON.parse(fs.readFileSync(path.join(__dirname, '../n8n/n8n_workflow_example.json'), 'utf8'));
const summary = workflow.nodes.find(node => node.name === 'Format backup summary').parameters.jsCode;
const validate = workflow.nodes.find(node => node.name === 'Validate backup result').parameters.jsCode;

function report(result, capacity = { code: 0, stdout: JSON.stringify({ status: 'success', total_bytes: 80 * 1024 ** 3, free_bytes: 59 * 1024 ** 3 }) }) {
  const context = {
    $: () => ({ first: () => ({ json: result }) }),
    $input: { first: () => ({ json: capacity }) },
    $now: { toISO: () => '2026-11-17T12:00:00Z' },
    $execution: { id: 'test-execution' },
  };
  return vm.runInNewContext('(function () {' + summary + '})()', context)[0].json;
}

const saved = {
  status: 'success', server_id: 'my-vps', temporary_files_cleaned: true,
  apps: [{ id: 'melodix', archive: '20261118T050000Z-a1B2c3D4.tar.gz', data_added: 2048 }],
};

test('completion report includes app, archive, uploaded bytes and pool capacity', () => {
  const output = report(saved);
  assert.match(output.message, /Backup complete/);
  assert.match(output.message, /melodix: saved.*2.0 KiB.*20261118T050000Z-a1B2c3D4.tar.gz/);
  assert.match(output.message, /59.0 GiB free \/ 80.0 GiB total/);
  assert.match(output.message, /Temporary files: cleaned/);
  assert.doesNotMatch(output.message, /password|repository|stdout/);
});

test('archive report distinguishes unchanged content from a skipped run', () => {
  const output = report({ ...saved, apps: [{ ...saved.apps[0], archive: 'app.tar.gz', data_added: 0, unchanged: true }] });
  assert.match(output.message, /Storage: archive/);
  assert.match(output.message, /melodix: unchanged/);
  assert.match(output.message, /New data uploaded: 0 B/);
});

test('guard skips never claim a new snapshot or uploaded data', () => {
  const output = report({ ...saved, apps: [], stage: 'skipped', skipped: true, last_success_at: 1794916800 });
  assert.match(output.message, /Backup skipped/);
  assert.match(output.message, /Last success:/);
  assert.match(output.message, /No new snapshot was created/);
  assert.doesNotMatch(output.message, /Backup complete|New data uploaded/);
});

test('capacity failure remains explicit and cannot leak SSH stderr', () => {
  for (const capacity of [{ code: 1, stderr: 'secret diagnostics' }, { code: 0, stdout: 'not json' }]) {
    const output = report(saved, capacity);
    assert.match(output.message, /Cloud space: unavailable/);
    assert.doesNotMatch(output.message, /secret diagnostics/);
  }
});

test('summary escapes Telegram HTML and bounds large app lists', () => {
  const output = report({ ...saved, server_id: '<host>&@everyone', apps: Array.from({ length: 100 }, () => ({ ...saved.apps[0], id: 'a'.repeat(63) })) });
  assert.match(output.telegramMessage, /&lt;host&gt;&amp;/);
  assert.doesNotMatch(output.message, /@everyone/);
  assert.match(output.message, /90 more apps/);
  assert.ok(output.message.length <= 2000);
});

test('failed backups and invalid SSH output cannot reach completion notifications', () => {
  assert.throws(() => report({ status: 'failed' }), /successful backup/);
  for (const ssh of [{ code: 1, stdout: '{}' }, { code: 0, stdout: 'invalid' }, { code: 0, stdout: '{"status":"failed"}' }]) {
    assert.throws(() => vm.runInNewContext('(function () {' + validate + '})()', { $input: { first: () => ({ json: ssh }) } }));
  }
});

test('template has independently disabled parallel destinations and no credentials', () => {
  for (const name of ['Discord', 'Telegram']) {
    const node = workflow.nodes.find(node => node.name === name);
    assert.equal(node.disabled, true);
    assert.equal(node.onError, 'continueRegularOutput');
    assert.ok(workflow.connections['Format backup summary'].main[0].some(edge => edge.node === name));
  }
  assert.ok(workflow.nodes.every(node => !node.credentials));
});

test('Discord embed groups status, apps and capacity within platform limits', () => {
  const completed = report(saved);
  const skipped = report({ ...saved, apps: [], skipped: true, last_success_at: 1794916800 });
  assert.notEqual(completed.discordEmbed.color, skipped.discordEmbed.color);
  assert.match(skipped.discordEmbed.title, /Already backed up/);
  assert.match(skipped.discordEmbed.description, /No new snapshot/);
  const cloud = completed.discordEmbed.fields.find(field => field.name.startsWith('Cloud storage'));
  assert.match(cloud.value, /[■□]{12}/);
  assert.match(cloud.value, /26% used/);
  const large = report({ ...saved, apps: Array.from({ length: 100 }, () => ({ ...saved.apps[0], id: 'a'.repeat(63) })) });
  assert.ok(large.discordEmbed.fields.every(field => field.value.length <= 1024));
  assert.ok(large.telegramMessage.length <= 4096);
  assert.match(large.telegramMessage, /<b>.*Backup complete/);
  assert.ok(!report(saved, { code: 1 }).discordEmbed.fields.at(-1).value.includes('■'));
});

test('archive embed keeps readable glyphs and the downloadable filename', () => {
  const output = report(saved);
  assert.match(output.discordEmbed.title, /✅|✓/);
  assert.ok(output.discordEmbed.fields.find(f => f.name === 'Applications').value.includes(saved.apps[0].archive));
  assert.doesNotMatch(output.discordEmbed.fields.find(f => f.name === 'Applications').value, /unknown/);
});
