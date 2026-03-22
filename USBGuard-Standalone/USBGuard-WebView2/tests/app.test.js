'use strict';

const {
  isValidPnpId,
  extractStatusJson,
  classifyLogLevel,
  stripLogPrefix,
  resolveNotifyTemplate,
  resolveCardState,
} = require('../wwwroot/app.js');

// ── isValidPnpId ─────────────────────────────────────────────────────────────

describe('isValidPnpId', () => {
  test.each([
    'USBSTOR\\DISK&VEN_SanDisk&PROD_Ultra&REV_1.00',
    'USBSTOR\\DISK&VEN_WD&PROD_MyPassport&REV_0001\\12345678',
    'USB#VID_0781&PID_5571',
    'WPD#WPD_0001',
    'BTHENUM#{00001105-0000-1000-8000-00805F9B34FB}',
    'A',
    'A'.repeat(200),
  ])('accepts valid PNP ID: %s', id => {
    expect(isValidPnpId(id)).toBe(true);
  });

  test.each([
    ['empty string',           ''],
    ['null',                   null],
    ['undefined',              undefined],
    ['space',                  'has space'],
    ['single quote',           "has'quote"],
    ['double quote',           'has"doublequote'],
    ['backtick',               'has`backtick'],
    ['dollar sign',            'has$dollar'],
    ['exclamation',            'has!exclaim'],
    ['open paren',             'has(paren'],
    ['close paren',            'has)paren'],
    ['pipe',                   'has|pipe'],
    ['less-than',              'has<angle'],
    ['greater-than',           'has>angle'],
    ['question mark',          'has?question'],
    ['asterisk',               'has*star'],
    ['plus',                   'has+plus'],
    ['equals',                 'has=equals'],
    ['tilde',                  'has~tilde'],
    ['caret',                  'has^caret'],
    ['percent',                'has%percent'],
    ['forward slash',          'has/slash'],
    ['newline injection',      'USBSTOR\nrm -rf /'],
    ['tab injection',          'USBSTOR\txxx'],
    ['201 chars (over limit)', 'A'.repeat(201)],
  ])('rejects %s', (_desc, id) => {
    expect(isValidPnpId(id)).toBe(false);
  });
});

// ── extractStatusJson ────────────────────────────────────────────────────────

describe('extractStatusJson', () => {
  test('parses JSON embedded in log output', () => {
    const output = [
      '[2026-03-22 10:00:00][INFO] Checking status...',
      '[2026-03-22 10:00:01][INFO] {"UsbStorage":"blocked","WriteProtect":"active"}',
    ].join('\n');
    const result = extractStatusJson(output);
    expect(result).toEqual({ UsbStorage: 'blocked', WriteProtect: 'active' });
  });

  test('parses JSON-only output (no log prefix)', () => {
    const json   = '{"UsbStorage":"blocked","MtpPtp":"blocked"}';
    const result = extractStatusJson(json);
    expect(result).toEqual({ UsbStorage: 'blocked', MtpPtp: 'blocked' });
  });

  test('handles multi-line JSON object', () => {
    const output = 'log line\n{"UsbStorage":"blocked",\n"SdCard":"blocked"}\n';
    const result = extractStatusJson(output);
    expect(result).not.toBeNull();
    expect(result.UsbStorage).toBe('blocked');
    expect(result.SdCard).toBe('blocked');
  });

  test('returns null for output with no JSON', () => {
    expect(extractStatusJson('[INFO] some log line')).toBeNull();
  });

  test('returns null for empty string', () => {
    expect(extractStatusJson('')).toBeNull();
  });

  test('returns null for null input', () => {
    expect(extractStatusJson(null)).toBeNull();
  });

  test('returns null for malformed JSON', () => {
    expect(extractStatusJson('{ not valid json }')).toBeNull();
  });

  test('returns first JSON object when multiple are present', () => {
    const output = '{"first":1} {"second":2}';
    const result = extractStatusJson(output);
    expect(result).toEqual({ first: 1 });
  });
});

// ── classifyLogLevel ─────────────────────────────────────────────────────────

describe('classifyLogLevel', () => {
  test.each([
    ['[2026-03-22 10:00:00][SUCCESS] USB storage blocked', 'success'],
    ['[2026-03-22 10:00:00][ERROR] Access denied',          'error'],
    ['[2026-03-22 10:00:00][WARN] Allowlist entry broad',   'warn'],
    ['[2026-03-22 10:00:00][INFO] Checking status',         'info'],
    ['some plain line without a level token',               'default'],
    ['',                                                    'default'],
  ])('classifies "%s" as %s', (line, expected) => {
    expect(classifyLogLevel(line)).toBe(expected);
  });

  test('SUCCESS takes precedence if multiple tokens present', () => {
    expect(classifyLogLevel('[SUCCESS] [ERROR] mixed')).toBe('success');
  });
});

// ── stripLogPrefix ───────────────────────────────────────────────────────────

describe('stripLogPrefix', () => {
  test('strips standard timestamp prefix', () => {
    const line = '[2026-03-22 14:05:01][INFO] USB storage blocked';
    expect(stripLogPrefix(line)).toBe('USB storage blocked');
  });

  test('strips ERROR-level prefix', () => {
    const line = '[2026-03-22 14:05:01][ERROR] Access denied';
    expect(stripLogPrefix(line)).toBe('Access denied');
  });

  test('strips SUCCESS-level prefix', () => {
    const line = '[2026-03-22 14:05:01][SUCCESS] Policy applied';
    expect(stripLogPrefix(line)).toBe('Policy applied');
  });

  test('returns line unchanged if no prefix present', () => {
    expect(stripLogPrefix('plain message')).toBe('plain message');
  });

  test('returns empty string unchanged', () => {
    expect(stripLogPrefix('')).toBe('');
  });
});

// ── resolveNotifyTemplate ─────────────────────────────────────────────────────

describe('resolveNotifyTemplate', () => {
  test('substitutes {COMPANY} with company name', () => {
    const result = resolveNotifyTemplate(
      'Blocked by {COMPANY} policy.',
      'Acme IT'
    );
    expect(result).toBe('Blocked by Acme IT policy.');
  });

  test('substitutes multiple {COMPANY} occurrences', () => {
    const result = resolveNotifyTemplate(
      '{COMPANY}: USB blocked. Contact {COMPANY} help desk.',
      'Contoso'
    );
    expect(result).toBe('Contoso: USB blocked. Contact Contoso help desk.');
  });

  test('returns template unchanged when no {COMPANY} placeholder', () => {
    const result = resolveNotifyTemplate('No placeholder here.', 'Acme');
    expect(result).toBe('No placeholder here.');
  });

  test('returns empty string for empty template', () => {
    expect(resolveNotifyTemplate('', 'Acme')).toBe('');
  });

  test('handles undefined company gracefully', () => {
    const result = resolveNotifyTemplate('Blocked by {COMPANY}.', undefined);
    expect(result).toBe('Blocked by .');
  });

  test('handles null template gracefully', () => {
    expect(resolveNotifyTemplate(null, 'Acme')).toBe('');
  });
});

// ── resolveCardState ──────────────────────────────────────────────────────────

describe('resolveCardState', () => {
  describe('WriteProtect', () => {
    test('active → blocked', () =>
      expect(resolveCardState('WriteProtect', 'active')).toBe('blocked'));
    test('inactive → allowed', () =>
      expect(resolveCardState('WriteProtect', 'inactive')).toBe('allowed'));
    test('unknown value → unknown', () =>
      expect(resolveCardState('WriteProtect', 'something')).toBe('unknown'));
    test('undefined → unknown', () =>
      expect(resolveCardState('WriteProtect', undefined)).toBe('unknown'));
  });

  describe('AutoPlayKilled', () => {
    test('disabled → blocked', () =>
      expect(resolveCardState('AutoPlayKilled', 'disabled')).toBe('blocked'));
    test('enabled → allowed', () =>
      expect(resolveCardState('AutoPlayKilled', 'enabled')).toBe('allowed'));
    test('other → unknown', () =>
      expect(resolveCardState('AutoPlayKilled', 'partial')).toBe('unknown'));
  });

  describe('VolumeWatcher', () => {
    test('running → blocked', () =>
      expect(resolveCardState('VolumeWatcher', 'running')).toBe('blocked'));
    test('ready → blocked', () =>
      expect(resolveCardState('VolumeWatcher', 'ready')).toBe('blocked'));
    test('not_installed → unknown', () =>
      expect(resolveCardState('VolumeWatcher', 'not_installed')).toBe('unknown'));
    test('stopped → unknown', () =>
      expect(resolveCardState('VolumeWatcher', 'stopped')).toBe('unknown'));
  });

  describe('direct-mapped fields (UsbStorage, MtpPtp, SdCard, etc.)', () => {
    test('blocked passes through', () =>
      expect(resolveCardState('UsbStorage', 'blocked')).toBe('blocked'));
    test('allowed passes through', () =>
      expect(resolveCardState('MtpPtp', 'allowed')).toBe('allowed'));
    test('unknown passes through', () =>
      expect(resolveCardState('SdCard', 'unknown')).toBe('unknown'));
    test('null → unknown fallback', () =>
      expect(resolveCardState('FireWire', null)).toBe('unknown'));
    test('undefined → unknown fallback', () =>
      expect(resolveCardState('BluetoothOBEX', undefined)).toBe('unknown'));
  });
});
