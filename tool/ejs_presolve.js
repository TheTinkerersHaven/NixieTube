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
// Requests are kept few on purpose: GitHub's runners share their
// addresses with a lot of scraping traffic, and YouTube answers a 429
// when it throttles one. So a run reads at most two pages per round (the
// watch page, then the embed page) and the player script only when a
// version is new; a 429 means "come back later": wait per `Retry-After`
// once per source, then leave the run green with a warning annotation
// (the hourly job tries again) rather than failing it.
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
const http = require('node:http');
const https = require('node:https');

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
  const options = { keep: 5, rounds: 2, force: false, dryRun: false };
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

/// Leaves the run green when YouTube throttled the runner: nothing was
/// published, nothing is broken, and the next cron run tries again. A red
/// X for a transient 429 trains everyone to ignore the job.
function rateLimitedSkip(error) {
  const retryAfter = error.retryAfterMs
    ? `, Retry-After ${Math.round(error.retryAfterMs / 1000)}s`
    : '';
  console.log(
    `::warning::ejs-presolve: YouTube is rate limiting this runner (429${retryAfter}); ` +
      'nothing published, the next scheduled run picks it up',
  );
  process.exit(0);
}

// --------------------------------------------------------------------
// Network
// --------------------------------------------------------------------

/// What actually went wrong, not just a wrapper error: the code and the
/// cause chain carry the DNS/TCP/TLS/HTTP detail, and that is the
/// difference between "the runner has no route to YouTube", "the response
/// was refused before it was read" and "YouTube said 429".
function describe(error) {
  if (!error) return 'unknown error';
  const parts = [];
  let current = error;
  for (let depth = 0; current && depth < 4; depth++) {
    const code = current.code ? `${current.code}: ` : '';
    parts.push(`(${code}${current.message ?? String(current)})`);
    current = current.cause;
  }
  return parts.length ? parts.join(' ') : String(error);
}

/// Google's frontends answer with large header blocks: the watch page
/// alone sends about 19 KB, of which `connection-allowlist-report-only`
/// is 7.4 KB and `Content-Security-Policy-Report-Only` 6.1 KB. That is
/// past undici's (the `fetch` global) 16 KiB ceiling, which it answers
/// with UND_ERR_HEADERS_OVERFLOW and no way to raise the limit, so the
/// requests go through node:https, which takes the limit as an option.
const MAX_HEADER_SIZE = 256 * 1024;

const MAX_REDIRECTS = 5;

const REQUEST_TIMEOUT = 60_000;

const REQUEST_HEADERS = {
  'User-Agent': USER_AGENT,
  'Accept-Language': 'en-US,en;q=0.9',
  Accept: 'text/html,application/xhtml+xml,application/javascript,*/*;q=0.8',
};

/// YouTube answering 429: the IP is being throttled, so the only useful
/// reaction is waiting. Carried as its own error so the caller can tell
/// "come back later" from "this is broken".
class RateLimited extends Error {
  constructor(url, retryAfterMs) {
    super(`HTTP 429 from ${url}`);
    this.name = 'RateLimited';
    this.retryAfterMs = retryAfterMs;
  }
}

/// One GET, following redirects, with the header limit raised. Resolves
/// with the UTF-8 body of the final 200 response.
function get(url, redirectsLeft = MAX_REDIRECTS) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const client = target.protocol === 'http:' ? http : https;
    const req = client.get(
      target,
      { headers: REQUEST_HEADERS, maxHeaderSize: MAX_HEADER_SIZE },
      (res) => {
        const status = res.statusCode ?? 0;
        if (status >= 300 && status < 400 && res.headers.location) {
          res.resume();
          if (redirectsLeft <= 0) {
            reject(new Error(`more than ${MAX_REDIRECTS} redirects`));
            return;
          }
          const next = new URL(res.headers.location, target).toString();
          resolve(get(next, redirectsLeft - 1));
          return;
        }
        if (status === 429) {
          res.resume();
          const header = Number(res.headers['retry-after']);
          const retryAfterMs =
            Number.isFinite(header) && header > 0 ? header * 1000 : null;
          reject(new RateLimited(target.toString(), retryAfterMs));
          return;
        }
        if (status !== 200) {
          res.resume();
          reject(new Error(`HTTP ${status}`));
          return;
        }
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
        res.on('error', reject);
      },
    );
    req.setTimeout(REQUEST_TIMEOUT, () => {
      req.destroy(new Error(`no response within ${REQUEST_TIMEOUT} ms`));
    });
    req.on('error', reject);
  });
}

/// Longest a 429 makes the run wait. `Retry-After` on these is often in
/// the minutes, which is more idling than a cron run is worth: one wait,
/// one retry, then the caller skips the run.
const MAX_RATE_LIMIT_WAIT = 60_000;

async function httpGet(url, what, attempts = 4) {
  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      const body = await get(url);
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
      if (error instanceof RateLimited) {
        // A 429 is the IP being throttled, not one unlucky request:
        // waiting per `Retry-After` once is worth it, repeating the
        // request is not.
        if (attempt > 1) break;
        const wait = Math.min(
          error.retryAfterMs ?? MAX_RATE_LIMIT_WAIT,
          MAX_RATE_LIMIT_WAIT,
        );
        console.error(
          `ejs-presolve: ${what}: rate limited, waiting ` +
            `${Math.round(wait / 1000)}s before the retry`,
        );
        await new Promise((resolve) => setTimeout(resolve, wait));
        continue;
      }
      if (attempt < attempts) {
        // Backoff with jitter: a runner that just lost its route often
        // recovers within a few seconds, and identical delays would keep
        // retrying in lockstep with other jobs.
        const wait = attempt * 3000 + Math.floor(Math.random() * 2000);
        await new Promise((resolve) => setTimeout(resolve, wait));
      }
    }
  }
  throw lastError instanceof RateLimited
    ? lastError
    : new Error(`${what}: ${describe(lastError)}`);
}

/// The player version and script path a YouTube page names.
///
/// Two sources, tried in order. The watch page is canonical; the embed
/// page is the fallback because it is the one Google throttles last (a
/// run whose watch page returned 429 for every attempt still got an
/// answer there). Its `player_embed_es6` script is a smaller build of the
/// same version and answers `sig`/`n` identically to `player_es6`, so an
/// artifact built from it is interchangeable for the app; when the two
/// pages name different versions, the artifact is simply published under
/// the id it came from.
async function discoverPlayer(videoId) {
  const sources = [
    `https://www.youtube.com/watch?v=${videoId}` +
      '&bpctr=9999999999999&has_verified=1',
    `https://www.youtube.com/embed/${videoId}`,
  ];
  let limited = null;
  for (const url of sources) {
    let html;
    try {
      html = await httpGet(url, `page ${url}`);
    } catch (error) {
      if (error instanceof RateLimited) {
        limited = error;
        console.error(`ejs-presolve: ${url}: rate limited, trying next source`);
      } else {
        console.error(`ejs-presolve: ${url}: ${error.message}`);
      }
      continue;
    }
    const match = html.match(WATCH_PLAYER_PATH);
    if (!match) {
      console.error(`ejs-presolve: ${url}: no player script path`);
      continue;
    }
    return { playerId: match[1], jsPath: match[0], rateLimited: limited != null };
  }
  if (limited) throw limited;
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
function publish(playerId, player, index, options, jsc, jsPath = null) {
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
    // Which script the artifact was built from: the watch page's
    // `player_es6` build or the embed page's smaller one. Same version,
    // same answers, but the branch is easier to reason about with the
    // provenance recorded.
    jsPath,
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
      publish(playerId, player, index, options, jsc, options.playerFile);
      if (!options.dryRun) writeIndex(options.outDir, index);
      return;
    }

    // YouTube serves a couple of player versions at once (A/B), so a
    // single discovery can name one while the app is handed the other.
    // Each round looks at the live site again; publishing one version
    // stops it from being solved twice, and the site's other version gets
    // picked up by the rounds that follow. Two rounds cover A/B; every
    // extra round is one more page request that can be rate limited.
    const seen = new Set();
    for (let round = 1; round <= options.rounds; round++) {
      try {
        const discovered = await discoverPlayer(options.video || PROBE_VIDEO);
        const playerId = discovered.playerId;
        if (seen.has(playerId)) continue;
        seen.add(playerId);
        const publishedBefore = index.players[playerId] != null;
        if (publishedBefore && !options.force) {
          console.log(`ejs-presolve: ${playerId} is already published`);
          if (index.latest !== playerId) index.latest = playerId;
        } else {
          console.log(
            `ejs-presolve: downloading player ${playerId} ` +
              `(${discovered.jsPath})`,
          );
          const player = await httpGet(
            `https://www.youtube.com${discovered.jsPath}`,
            'player script',
          );
          jsc = jsc || loadSolver();
          publish(playerId, player, index, options, jsc, discovered.jsPath);
        }
        // A throttled source is still throttled seconds later, so another
        // round would only re-ask the same page and wait again: sampling
        // for the A/B version can wait for the next run.
        if (discovered.rateLimited) {
          console.log(
            'ejs-presolve: a source was rate limited, not sampling more rounds',
          );
          break;
        }
      } catch (error) {
        if (!(error instanceof RateLimited)) throw error;
        // Everything published above is still written below, so the
        // branch stays consistent; a run that published nothing is a
        // skip for this hour, not a failure.
        if (seen.size === 0) throw error;
        console.log(
          '::warning::ejs-presolve: rate limited, stopping after the ' +
            'versions already published',
        );
        break;
      }
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
    if (error instanceof RateLimited) rateLimitedSkip(error);
    fail(error && error.stack ? error.stack : error);
  }
}

main().catch((error) => {
  if (error instanceof RateLimited) rateLimitedSkip(error);
  fail(error && error.stack ? error.stack : error);
});
