/**
 * RojaFume pre-launch signup endpoint.
 *
 * Receives a signup from index.html, appends it to a Google Sheet, and emails
 * a notification to NOTIFY_EMAIL.
 *
 * Setup lives in ../README.md. Short version: paste this into a Sheet-bound
 * Apps Script project, run setup() once, then deploy as a Web App with
 * "Execute as: Me" and "Who has access: Anyone".
 */

// ─── Config ──────────────────────────────────────────────────────────────────

var NOTIFY_EMAIL = 'rojaperfumes0405@gmail.com';
var SHEET_NAME = 'Signups';

// The id from the spreadsheet's own URL:
//   https://docs.google.com/spreadsheets/d/<THIS_PART>/edit
// Filling this in is the most reliable option: it removes all dependence on
// getActiveSpreadsheet(), on setup() having run, and on deployment ordering.
// Leave blank only if you want it resolved automatically (see getSpreadsheet).
var SPREADSHEET_ID = '';

// Diagnostics switch. When a Script Property named DEBUG_TOKEN is set, a request
// carrying that exact value in its "debug" field gets the real error back instead
// of the generic "Server error"; everyone else still sees the generic message.
//
// It lives in Script Properties rather than in this file because this file is in
// a public GitHub repo. It is also read on every request, so setting or clearing
// the property switches diagnostics on and off with NO redeploy.
//
//   Apps Script editor -> Project Settings -> Script Properties -> Add
//   Property: DEBUG_TOKEN   Value: any random string
//
// Delete the property once you are done.

var HEADERS = ['Timestamp', 'Name', 'Email', 'Phone', 'Page'];

// ─── Entry points ────────────────────────────────────────────────────────────

/** Health check — opening the /exec URL in a browser should show {"ok":true}. */
function doGet() {
  return json({ ok: true, service: 'rojafume-signup' });
}

function doPost(e) {
  try {
    var data = parseBody(e);
    if (!data) {
      return json({ ok: false, error: 'Bad request' });
    }

    // Honeypot: a real visitor never sees this field. Answer as if it worked
    // so the bot has no signal to adapt to, but write nothing.
    if (String(data.company || '').trim() !== '') {
      return json({ ok: true });
    }

    var name = clean(data.name, 80);
    var email = clean(data.email, 254);
    var phone = clean(data.phone, 24);
    var page = clean(data.page, 300);

    // Never trust the client's validation — repeat it here.
    var problem = validate(name, email, phone);
    if (problem) {
      return json({ ok: false, error: problem });
    }

    // One writer at a time, so two simultaneous signups cannot both pass the
    // duplicate check and append the same email twice.
    var lock = LockService.getScriptLock();
    if (!lock.tryLock(20000)) {
      return json({ ok: false, error: 'Busy, please retry' });
    }

    try {
      var sheet = getSheet();

      if (hasEmail(sheet, email)) {
        return json({ ok: true, duplicate: true });
      }

      sheet.appendRow([
        new Date(),
        safeCell(name),
        safeCell(email),
        safeCell(phone),
        safeCell(page)
      ]);
    } finally {
      lock.releaseLock();
    }

    // A failed notification must not fail the signup — the row is already safe.
    try {
      notify(name, email, phone, page);
    } catch (mailErr) {
      console.error('Notification email failed: ' + mailErr);
    }

    return json({ ok: true });
  } catch (err) {
    // Log the detail, return something generic — unless the caller proved it is
    // you by sending the debug token, in which case hand back the real reason.
    console.error('doPost failed: ' + err + (err && err.stack ? '\n' + err.stack : ''));

    var reply = { ok: false, error: 'Server error' };
    if (debugTokenMatches(data)) {
      // Nothing in here may throw, or the caller gets an HTML error page
      // instead of JSON.
      try {
        reply.detail = String(err && err.message ? err.message : err);
        reply.stack = String((err && err.stack) || '').substring(0, 300);
        reply.configuredSpreadsheetId = SPREADSHEET_ID || null;
        reply.cachedSpreadsheetId =
          PropertiesService.getScriptProperties().getProperty('SPREADSHEET_ID') || null;
      } catch (probeErr) {
        reply.detail = 'could not read diagnostics: ' + probeErr;
      }
    }
    return json(reply);
  }
}

// ─── Sheet ───────────────────────────────────────────────────────────────────

/**
 * getActiveSpreadsheet() is reliable in the editor but returns null inside an
 * anonymous web-app POST, which is why a signup can fail even though setup()
 * worked. So: use the configured id, else the one setup() cached, else fall
 * back to the active spreadsheet and cache its id for next time.
 */
function getSpreadsheet() {
  if (SPREADSHEET_ID) {
    return SpreadsheetApp.openById(SPREADSHEET_ID);
  }

  var props = PropertiesService.getScriptProperties();
  var cached = props.getProperty('SPREADSHEET_ID');
  if (cached) {
    return SpreadsheetApp.openById(cached);
  }

  var active = SpreadsheetApp.getActiveSpreadsheet();
  if (active) {
    props.setProperty('SPREADSHEET_ID', active.getId());
    return active;
  }

  throw new Error(
    'No spreadsheet available. Run setup() once from the Apps Script editor ' +
    'so the spreadsheet id gets cached, then redeploy.');
}

function getSheet() {
  var ss = getSpreadsheet();
  var sheet = ss.getSheetByName(SHEET_NAME);

  if (!sheet) {
    sheet = ss.insertSheet(SHEET_NAME);
  }
  if (sheet.getLastRow() === 0) {
    sheet.appendRow(HEADERS);
    sheet.getRange(1, 1, 1, HEADERS.length).setFontWeight('bold');
    sheet.setFrozenRows(1);
  }
  return sheet;
}

/** Case-insensitive lookup over the Email column. */
function hasEmail(sheet, email) {
  var lastRow = sheet.getLastRow();
  if (lastRow < 2) { return false; }

  var emailCol = HEADERS.indexOf('Email') + 1;
  var values = sheet.getRange(2, emailCol, lastRow - 1, 1).getValues();
  var needle = email.toLowerCase();

  for (var i = 0; i < values.length; i++) {
    if (String(values[i][0]).trim().toLowerCase() === needle) {
      return true;
    }
  }
  return false;
}

// ─── Notification ────────────────────────────────────────────────────────────

function notify(name, email, phone, page) {
  var subject = 'New RojaFume pre-launch signup — ' + name;

  var rows = [
    ['Name', name],
    ['Email', email],
    ['Phone', phone],
    ['Page', page],
    ['Received', Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'd MMM yyyy, h:mm a')]
  ];

  var cells = rows.map(function (row) {
    return '<tr>' +
      '<td style="padding:6px 16px 6px 0;color:#8a7a55;font:12px system-ui,sans-serif;' +
      'letter-spacing:.08em;text-transform:uppercase;vertical-align:top">' + esc(row[0]) + '</td>' +
      '<td style="padding:6px 0;color:#1a1a1a;font:15px system-ui,sans-serif">' + esc(row[1]) + '</td>' +
      '</tr>';
  }).join('');

  var html =
    '<div style="font:15px system-ui,sans-serif;color:#1a1a1a;max-width:520px">' +
      '<p style="margin:0 0 4px;font:600 11px system-ui,sans-serif;letter-spacing:.28em;' +
      'text-transform:uppercase;color:#b8963e">RojaFume</p>' +
      '<h2 style="margin:0 0 18px;font:400 22px Georgia,serif">New pre-launch signup</h2>' +
      '<table cellpadding="0" cellspacing="0">' + cells + '</table>' +
      '<p style="margin:22px 0 0;font:12px system-ui,sans-serif;color:#777">' +
      'Saved to the ' + esc(SHEET_NAME) + ' sheet.</p>' +
    '</div>';

  var plain = rows.map(function (row) { return row[0] + ': ' + row[1]; }).join('\n');

  MailApp.sendEmail({
    to: NOTIFY_EMAIL,
    subject: subject,
    body: plain,
    htmlBody: html,
    name: 'RojaFume Pre-launch',
    replyTo: email
  });
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

function parseBody(e) {
  if (!e || !e.postData || !e.postData.contents) { return null; }
  try {
    var data = JSON.parse(e.postData.contents);
    return (data && typeof data === 'object' && !Array.isArray(data)) ? data : null;
  } catch (err) {
    return null;
  }
}

function clean(value, maxLength) {
  return String(value == null ? '' : value)
    .replace(/\s+/g, ' ')  // collapse newlines, tabs and runs of spaces
    .trim()
    .slice(0, maxLength);
}

function validate(name, email, phone) {
  if (name.length < 2) { return 'Invalid name'; }
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) {
    return 'Invalid email';
  }
  var digits = phone.replace(/\D/g, '');
  if (digits.length < 7 || digits.length > 15) { return 'Invalid phone'; }
  return null;
}

/**
 * Sheets treats a leading =, +, - or @ as a formula. Prefixing with an
 * apostrophe forces the value to stay text.
 */
function safeCell(value) {
  var s = String(value == null ? '' : value);
  return /^[=+\-@]/.test(s) ? "'" + s : s;
}

function esc(value) {
  return String(value == null ? '' : value).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
  });
}

/**
 * True only when the caller sent the exact value held in the DEBUG_TOKEN script
 * property. No property set (the normal state) means no caller can ever unlock
 * the diagnostics, whatever they send.
 */
function debugTokenMatches(data) {
  if (!data || typeof data.debug !== 'string' || !data.debug) { return false; }
  try {
    var expected = PropertiesService.getScriptProperties().getProperty('DEBUG_TOKEN');
    return !!expected && data.debug === expected;
  } catch (err) {
    return false;
  }
}

function json(payload) {
  return ContentService
    .createTextOutput(JSON.stringify(payload))
    .setMimeType(ContentService.MimeType.JSON);
}

// ─── One-time setup / test ───────────────────────────────────────────────────

/**
 * Run this once from the Apps Script editor. It creates the sheet with its
 * header row and triggers the Gmail permission prompt by sending you a test
 * notification.
 */
function setup() {
  var props = PropertiesService.getScriptProperties();
  var active = SpreadsheetApp.getActiveSpreadsheet();

  if (!active && !SPREADSHEET_ID) {
    throw new Error(
      'setup() must run from the Apps Script project bound to the Sheet ' +
      '(Extensions > Apps Script), or set SPREADSHEET_ID at the top of this file.');
  }
  if (active) {
    // The web app cannot call getActiveSpreadsheet(), so remember the id now.
    props.setProperty('SPREADSHEET_ID', active.getId());
  }

  getSheet();
  notify('Test Signup', NOTIFY_EMAIL, '+91 00000 00000', 'setup()');

  console.log('Spreadsheet id cached: ' + (SPREADSHEET_ID || props.getProperty('SPREADSHEET_ID')));
  console.log('Sheet ready and a test email was sent to ' + NOTIFY_EMAIL);
}

/**
 * Run this from the editor if a signup fails. It exercises the same path the
 * web app takes and prints where it breaks.
 */
function diagnose() {
  var res = doPost({
    postData: {
      contents: JSON.stringify({
        name: 'DELETE ME - diagnose()',
        email: 'diagnose.' + Date.now() + '@example.com',
        phone: '+91 00000 00000',
        page: 'diagnose()'
      })
    }
  });
  console.log('doPost returned: ' + res.getContent());
  console.log('Cached spreadsheet id: ' +
    PropertiesService.getScriptProperties().getProperty('SPREADSHEET_ID'));
}
