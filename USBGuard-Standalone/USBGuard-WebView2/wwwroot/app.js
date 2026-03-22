'use strict';

// ── Pure utility functions (no DOM, no WebView2 dependency) ──────────────────
// These are exported for unit testing. When running in the browser they are
// available globally because index.html loads this file before its own script.

/**
 * Returns true if s is a valid Windows PNP Device ID.
 * Rejects empty strings, strings > 200 chars, and any shell metacharacters.
 * Mirrors the regex in InputValidator.cs so host and renderer agree.
 * @param {string} s
 * @returns {boolean}
 */
function isValidPnpId(s) {
  if (!s || typeof s !== 'string') return false;
  return /^[A-Za-z0-9_\-\\&\.\{\}@#]{1,200}$/.test(s);
}

/**
 * Extracts and parses the first JSON object from a PowerShell output string.
 * USBGuard.ps1 writes log lines before the JSON — this skips them.
 * Returns null if no valid JSON object is found or parsing fails.
 * @param {string} output - raw stdout from USBGuard.ps1 -Action status
 * @returns {object|null}
 */
function extractStatusJson(output) {
  if (!output) return null;
  const m = output.match(/\{[\s\S]*\}/);
  if (!m) return null;
  try {
    return JSON.parse(m[0]);
  } catch {
    return null;
  }
}

/**
 * Classifies a single line of USBGuard.ps1 output into a log level.
 * Returns one of: 'success' | 'error' | 'warn' | 'info' | 'default'
 * @param {string} line
 * @returns {string}
 */
function classifyLogLevel(line) {
  if (line.includes('[SUCCESS]')) return 'success';
  if (line.includes('[ERROR]'))   return 'error';
  if (line.includes('[WARN]'))    return 'warn';
  if (line.includes('[INFO]'))    return 'info';
  return 'default';
}

/**
 * Strips the USBGuard log timestamp prefix from a line.
 * Input:  "[2026-03-22 14:05:01][INFO] USB storage blocked"
 * Output: "USB storage blocked"
 * @param {string} line
 * @returns {string}
 */
function stripLogPrefix(line) {
  return line.replace(/^\[\d{4}-\d{2}-\d{2}\s[\d:]+\]\[[\w]+\]\s*/, '');
}

/**
 * Resolves {COMPANY} placeholders in a notification message template.
 * @param {string} template - message text, may contain {COMPANY}
 * @param {string} company  - company name to substitute
 * @returns {string}
 */
function resolveNotifyTemplate(template, company) {
  if (!template) return '';
  return template.replace(/\{COMPANY\}/g, company || '');
}

/**
 * Maps a raw PS status field value to a display state string.
 * Used by updateCard in the renderer; exposed here for testing.
 *
 * @param {'WriteProtect'|'AutoPlayKilled'|'VolumeWatcher'} field
 * @param {string} rawValue - value from the PS JSON status object
 * @returns {string} state key: 'blocked' | 'allowed' | 'unknown'
 */
function resolveCardState(field, rawValue) {
  switch (field) {
    case 'WriteProtect':
      return rawValue === 'active'   ? 'blocked'
           : rawValue === 'inactive' ? 'allowed'
           : 'unknown';
    case 'AutoPlayKilled':
      return rawValue === 'disabled' ? 'blocked'
           : rawValue === 'enabled'  ? 'allowed'
           : 'unknown';
    case 'VolumeWatcher':
      return (rawValue === 'running' || rawValue === 'ready') ? 'blocked' : 'unknown';
    default:
      // Most fields map directly: 'blocked', 'allowed', 'unknown', 'partial', 'not_installed'
      return rawValue || 'unknown';
  }
}

// ── Node.js / Jest export ─────────────────────────────────────────────────────
// This block is stripped by the browser (no module.exports in browser context).
if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    isValidPnpId,
    extractStatusJson,
    classifyLogLevel,
    stripLogPrefix,
    resolveNotifyTemplate,
    resolveCardState,
  };
}
