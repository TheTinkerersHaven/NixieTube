#!/usr/bin/env node
// Pre-solves the YouTube player's `sig` / `n` challenges off the device.
//
// The app's EJS bundle answers those challenges by parsing the whole
// ~2.6 MB player script with meriyah and printing the pieces back out
// with astring. On Node that pass costs about 0.7 s; on an engine without
// a JIT (the QuickJS that flutter_js ships) it costs minutes, which is
// what this job exists to avoid.
//
// The pass is player-global and independent of the challenge values, so
// it can run once per player version instead of once per play: the EJS
// core answers with `preprocessed_player`, a self-contained script whose
// `_result.sig` / `_result.n` entry points serve every challenge until
// YouTube rotates base.js. This tool produces that artifact, checks it
// against the full-player solve, and publishes it keyed by player
// version. The app fetches the artifact and evaluates it directly — the
// same bundle, the same answer, no AST pass, and not even the 2.6 MB
// player download.
//
// Usage:
//   node tool/ejs_presolve.js --out <dir>
//       Discover the current player, solve it, write `<dir>/<id>.js` and
//       refresh `<dir>/index.json`. Does nothing when the version is
//       already published.
//   node tool/ejs_presolve.js --out <dir> --player-file <base.js> --player-id <id>
//       Solve a local copy instead of downloading (offline verification).
//
// Options:
//   --out DIR        where the artifacts and index.json live (required)
//   --keep N         artifacts to keep in DIR, newest first (default 5)
//   --video ID       video whose watch page names the current player
//   --player-id ID   player version, skipping watch-page discovery
//   --player-file F  read the player script from F instead of the network
//   --force          re-solve even when the version is already published
//   --dry-run        do all the work but write nothing

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const dns = require('node:dns');

// GitHub's runners regularly have no usable IPv6 route, and undici tries
// AAAA records first: the request then dies as "fetch failed" instead of
// falling back. IPv4 first costs nothing where IPv6 works.
dns.setDefaultResultOrder('ipv4first');

/// The vendored EJS bundle, shared with the app (assets/js).
const BUNDLE_DIR = path.join(__dirname, '..', 'assets', 'js');

/// The browser the app presents to YouTube's WEB_REMIX client.
const USER_AGENT =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) ' +
  'Gecko/20100101 Firefox/140.0';

/// The watch page whose player a discovery run reads. Any public video
/// works — the page names the player script the whole site uses — so a
/// long-lived one is picked to keep this stable.
const PROBE_VIDEO = 'dQw4w9WgXcQ';

const WATCH_PLAYER_PATH = /\/s\/player\/([A-Za-z0-9_-]+)\/[^"'\s<>]*base\.js/;

/// Samples the artifact is checked against. The values are arbitrary
/// (they are inputs to the extracted functions), but they look like the
/// real ones, so a solve that only works for degenerate input fails here.
const SAMPLES = {
  sig: [
    'AOYcqS1VdKp8fQmO6hS1-2m9Jk1c8bX4x',
    'B7kLm2nQp9Rs4tUv1Wx6Yz3Ab8Cd5Ef0Gh',
    'CwErTyUiOpAsDfGhJkLzXcVbNmQwErTyUi',
  ],
  n: [
    'bq0Q4FzXe6QKj8Yv2mN1pR7sT3uV5wX9yZ0aB1cD2eF3gH4iJ5kL6mN7oP8qR9sT0uV1wX2yZ',
    'aP9oI8uY7tR6eW5qA4sD3fG2hJ1kL0zX9cV8bN7mQ6wE5rT4yU3iO2pS1dB0gH9jK8lM',
    'mN8bV7cX6zL5kJ4hG3fD2sA1pO9iU8yT7rE6wQ5qZ4xC3vB2nM1lK0jH9gF8dS7aP6oI5u',
  ],
};

// --------------------------------------------------------------------
// Argument handling
// --------------------------------------------------------------------

function parseArgs(argv) {
  const options = { keep: 5, rounds: 3, force: false, dryRun: false };
  const valued = {
    '--out': 'out',
    '--keep': 'keep',
    '--rounds': 'rounds',
    '--video': 'video',
    '--player-id': 'playerId',
    '--player-file': 'playerFile',
  };
  const numeric = new Set(['keep', 'rounds']);
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--force') {
      options.force = true;
      continue;
    }
    if (arg === '--dry-run') {
      options.dryRun = true;
      continue;
    }
    const key = valued[arg];
    if (key == null) fail(`unknown argument: ${arg}`);
    const value = argv[++i];
    if (value == null) fail(`${arg} needs a value`);
    options[key] = numeric.has(key) ? Number(value) : value;
  }
  if (!options.out) fail('--out is required');
  for (const key of numeric) {
    if (!Number.isInteger(options[key]) || options[key] < 1) {
      fail(`--${key} must be a positive integer`);
    }
  }
  return options;
}

function fail(message) {
  console.error(`ejs-presolve: ${message}`);
  process.exit(1);
}

// --------------------------------------------------------------------
// Network
// --------------------------------------------------------------------

/// What actually went wrong, not just undici's "fetch failed" wrapper:
/// the cause carries the DNS/TCP/TLS detail, and that is the difference
/// between "the runner has no route to YouTube" and "YouTube said 429".
function describe(error) {
  if (!error) return 'unknown error';
  const parts = [error.message ?? String(error)];
  let cause = error.cause;
  for (let depth = 0; cause && depth < 3; depth++) {
    const code = cause.code ? `${cause.code}: ` : '';
    parts.push(`(${code}${cause.message ?? String(cause)})`);
    cause = cause.cause;
  }
  return parts.join(' ');
}

async function httpGet(url, what, attempts = 4) {
  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      const res = await fetch(url, {
        headers: {
          'User-Agent': USER_AGENT,
          'Accept-Language': 'en-US,en;q=0.9',
        },
        redirect: 'follow',
        signal: AbortSignal.timeout(120_000),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const body = await res.text();
      if (!body) throw new Error('empty body');
      return body;
    } catch (error) {
      lastError = error;
      // Every attempt is logged: a run that dies in CI has to say what
      // was tried and why it failed, or the log is a single opaque line.
      console.error(
        `ejs-presolve: ${what}: attempt ${attempt}/${attempts} failed: ` +
          describe(error),
      );
      if (attempt < attempts) {
        // Backoff with jitter: a runner that just lost its route often
        // recovers within a few seconds, and identical delays would keep
        // retrying in lockstep with other jobs.
        const wait = attempt * 3000 + Math.floor(Math.random() * 2000);
        await new Promise((resolve) => setTimeout(resolve, wait));
      }
    }
  }
  throw new Error(`${what}: ${describe(lastError)}`);
}

/// The player version and script path the current watch page names.
async function discoverPlayer(videoId) {
  // Several entry points: the watch page is the canonical one, but a
  // blocked or redirected fetch of it must not decide the whole run.
  const pages = [
    `https://www.youtube.com/watch?v=${videoId}&bpctr=9999999999999&has_verified=1`,
    `https://m.youtube.com/watch?v=${videoId}`,
    `https://www.youtube.com/embed/${videoId}`,
  ];
  for (const page of pages) {
    let html;
    try {
      html = await httpGet(page, `watch page ${page}`);
    } catch (error) {
      console.error(`ejs-presolve: ${error.message}`);
      continue;
    }
    const match = html.match(WATCH_PLAYER_PATH);
    if (match) return { playerId: match[1], jsPath: match[0] };
  }
  fail('no player script path on the watch page');
}

// --------------------------------------------------------------------
// The EJS bundle
// --------------------------------------------------------------------

/// The player script runs inside a document, so the bundle needs the
/// globals a browser would provide. Only the handful the solve touches
/// are stubbed, exactly as the app's WebView and the yt-dlp monitors do.
/// Node defines some of them as read-only accessors, so each is set
/// through a definition instead of an assignment.
function installBrowserGlobals() {
  const globals = {
    window: globalThis,
    self: globalThis,
    XMLHttpRequest: { prototype: {} },
    document: {
      createElement: () => ({ style: {}, canPlayType: () => '' }),
      head: { appendChild: () => {} },
      documentElement: {},
      addEventListener: () => {},
    },
    navigator: { userAgent: USER_AGENT, languages: ['en-US'] },
    location: { hostname: 'www.youtube.com', href: 'https://www.youtube.com/' },
  };
  for (const [name, value] of Object.entries(globals)) {
    Object.defineProperty(globalThis, name, {
      value,
      writable: true,
      configurable: true,
    });
  }
}

/// Loads the vendored solver bundle and returns its `jsc(request)`. The
/// files are the app's own, so CI runs the exact bytes a release ships.
///
/// Both bundles declare their entry point with `var` and are read through
/// [Function] bodies: the declaration stays local to the wrapper and the
/// core gets meriyah/astring as parameters instead of globals, which
/// keeps this tool from depending on eval scoping rules.
function loadSolver() {
  installBrowserGlobals();
  const dir = BUNDLE_DIR;
  const libSrc = fs.readFileSync(path.join(dir, 'yt.solver.lib.js'), 'utf8');
  const coreSrc = fs.readFileSync(
    path.join(dir, 'yt.solver.core.min.js'),
    'utf8',
  );
  const lib = new Function(`${libSrc}\nreturn lib;`)();
  if (!lib || !lib.meriyah || !lib.astring) {
    fail('yt.solver.lib.js does not define meriyah and astring');
  }
  const jsc = new Function(
    'meriyah',
    'astring',
    `${coreSrc}\nreturn jsc;`,
  )(lib.meriyah, lib.astring);
  if (typeof jsc !== 'function') fail('yt.solver.core.min.js defines no jsc');
  return jsc;
}

function requests() {
  return [
    { type: 'sig', challenges: SAMPLES.sig },
    { type: 'n', challenges: SAMPLES.n },
  ];
}

/// Answers the sample challenges from the raw player script and returns
/// both the responses and the artifact generated along the way.
function solveFullPlayer(jsc, player) {
  return jsc({
    type: 'player',
    player,
    requests: requests(),
    output_preprocessed: true,
  });
}

/// Answers the same challenges from an already pre-solved artifact: the
/// call the app makes, with no AST pass in the way.
function solvePreprocessed(jsc, preprocessed) {
  return jsc({
    type: 'preprocessed',
    preprocessed_player: preprocessed,
    requests: requests(),
  });
}

/// The solved values, or a marker for the failure, so two runs can be
/// compared without caring which shape they took.
function outcome(response) {
  if (response.type === 'result') {
    return { type: 'result', data: response.data };
  }
  return { type: 'error', error: String(response.error) };
}

/// Checks the artifact against the full-player solve: it must answer
/// every request, and answer it identically. A player whose functions the
/// bundle cannot extract fails here, which is the signal that YouTube
/// changed something and the vendored bundle needs patching.
function verify(jsc, full, preprocessed) {
  const fromPreprocessed = solvePreprocessed(jsc, preprocessed);
  const expected = full.responses.map(outcome);
  const actual = fromPreprocessed.responses.map(outcome);
  if (JSON.stringify(expected) !== JSON.stringify(actual)) {
    const detail = JSON.stringify({ expected, actual }, null, 2);
    fail(`the artifact does not match the full-player solve:\n${detail}`);
  }
  for (const response of actual) {
    if (response.type !== 'result') {
      fail(
        `the solver could not extract a challenge function: ${response.error}`,
      );
    }
    for (const [challenge, value] of Object.entries(response.data)) {
      if (typeof value !== 'string' || value.length === 0) {
        fail(`empty answer for ${JSON.stringify(challenge)}`);
      }
    }
  }
  return actual;
}

// --------------------------------------------------------------------
// Publishing
// --------------------------------------------------------------------

function sha256(text) {
  return crypto.createHash('sha256').update(text).digest('hex');
}

function readIndex(outDir) {
  try {
    const raw = fs.readFileSync(path.join(outDir, 'index.json'), 'utf8');
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object' && parsed.players) return parsed;
  } catch (_) {}
  return { latest: null, players: {} };
}

function writeIndex(outDir, index) {
  const ordered = {};
  const entries = Object.entries(index.players).sort((a, b) =>
    String(b[1].created).localeCompare(String(a[1].created)),
  );
  for (const [id, entry] of entries) ordered[id] = entry;
  const body = JSON.stringify(
    { latest: index.latest, players: ordered },
    null,
    2,
  );
  fs.writeFileSync(path.join(outDir, 'index.json'), `${body}\n`);
}

/// Keeps the newest [keep] artifacts and drops the rest, so the branch
/// does not grow a multi-megabyte file per player rotation forever.
function prune(outDir, index, keep) {
  const ordered = Object.entries(index.players).sort((a, b) =>
    String(b[1].created).localeCompare(String(a[1].created)),
  );
  const dropped = [];
  for (const [id] of ordered.slice(keep)) {
    const file = path.join(outDir, `${id}.js`);
    if (fs.existsSync(file)) fs.unlinkSync(file);
    delete index.players[id];
    dropped.push(id);
  }
  return dropped;
}

// --------------------------------------------------------------------

/// Solves one player script and publishes it. Returns true when a new
/// artifact was written.
function publish(playerId, player, index, options, jsc) {
  if (player.length < 100_000) {
    fail(`the player script is only ${player.length} bytes; refusing to solve`);
  }
  console.log(
    `ejs-presolve: solving ${playerId}, ` +
      `${(player.length / 1024).toFixed(0)} KB of player`,
  );
  const started = Date.now();
  const full = solveFullPlayer(jsc, player);
  const artifact = full.preprocessed_player;
  if (typeof artifact !== 'string' || artifact.length < 1024) {
    fail('the solver produced no preprocessed player');
  }
  const solved = verify(jsc, full, artifact);
  const elapsed = Date.now() - started;

  console.log(
    `ejs-presolve: solved ${playerId} in ${elapsed} ms, artifact ` +
      `${(artifact.length / 1024).toFixed(0)} KB`,
  );
  for (const response of solved) {
    console.log(`  ${response.type}: ${JSON.stringify(response.data)}`);
  }

  const solvedAt = new Date().toISOString();
  index.players[playerId] = {
    created: index.players[playerId]?.created ?? solvedAt,
    solvedAt,
    bytes: artifact.length,
    sha256: sha256(artifact),
    playerBytes: player.length,
    playerSha256: sha256(player),
  };
  index.latest = playerId;

  if (options.dryRun) {
    console.log(`ejs-presolve: dry run, not writing ${playerId}.js`);
    return false;
  }
  fs.writeFileSync(path.join(options.outDir, `${playerId}.js`), artifact);
  console.log(`ejs-presolve: wrote ${playerId}.js`);
  return true;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  options.outDir = path.resolve(options.out);
  if (!options.dryRun) fs.mkdirSync(options.outDir, { recursive: true });

  const index = readIndex(options.outDir);
  let jsc;
  try {
    // A local script is solved on its own; no discovery, no network.
    if (options.playerFile) {
      const player = fs.readFileSync(options.playerFile, 'utf8');
      const playerId = options.playerId || sha256(player).slice(0, 16);
      jsc = loadSolver();
      publish(playerId, player, index, options, jsc);
      if (!options.dryRun) writeIndex(options.outDir, index);
      return;
    }

    // YouTube serves a couple of player versions at once (A/B), so a
    // single discovery can name one while the app is handed the other.
    // Each round looks at the live site again; publishing one version
    // stops it from being solved twice, and the site's other version gets
    // picked up by the rounds that follow.
    const seen = new Set();
    for (let round = 1; round <= options.rounds; round++) {
      const discovered = await discoverPlayer(options.video || PROBE_VIDEO);
      const playerId = discovered.playerId;
      if (seen.has(playerId)) continue;
      seen.add(playerId);
      const publishedBefore = index.players[playerId] != null;
      if (publishedBefore && !options.force) {
        console.log(`ejs-presolve: ${playerId} is already published`);
        if (index.latest !== playerId) index.latest = playerId;
        continue;
      }
      console.log(
        `ejs-presolve: downloading player ${playerId} (${discovered.jsPath})`,
      );
      const player = await httpGet(
        `https://www.youtube.com${discovered.jsPath}`,
        'player script',
      );
      jsc = jsc || loadSolver();
      publish(playerId, player, index, options, jsc);
    }

    if (!options.dryRun) {
      const dropped = prune(options.outDir, index, options.keep);
      writeIndex(options.outDir, index);
      if (dropped.length) {
        console.log(`ejs-presolve: pruned ${dropped.join(', ')}`);
      }
    }
    console.log(`ejs-presolve: ${seen.size} player version(s) seen`);
  } catch (error) {
    fail(error && error.stack ? error.stack : error);
  }
}

main().catch((error) => fail(error && error.stack ? error.stack : error));
