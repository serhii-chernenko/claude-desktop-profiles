ObjC.import('Foundation');
ObjC.import('stdlib');

const REGISTRY_FILE = 'git-worktrees.json';
const SESSIONS_DIR = 'claude-code-sessions';
const SESSION_FILE_PATTERN = /^local_.*\.json$/;
const EMPTY_FIELD = '-';
const CONTROL_CHARACTERS = new RegExp('[\\u0000-\\u001f\\u007f\\u0085\\u2028\\u2029]', 'g');

function fail(message) {
  const data = $(message + '\n').dataUsingEncoding($.NSUTF8StringEncoding);
  $.NSFileHandle.fileHandleWithStandardError.writeData(data);
  $.exit(1);
}

function fileExists(path) {
  return $.NSFileManager.defaultManager.fileExistsAtPath(path);
}

function readJson(path) {
  const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  if (!text || text.isNil()) fail('worktrees.js: cannot read ' + path);
  try {
    return JSON.parse(ObjC.unwrap(text));
  } catch (error) {
    fail('worktrees.js: invalid JSON in ' + path + ': ' + error.message);
  }
}

function tryJson(path) {
  const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  if (!text || text.isNil()) return null;
  try {
    return JSON.parse(ObjC.unwrap(text));
  } catch (error) {
    return null;
  }
}

function childNames(directory) {
  const names = $.NSFileManager.defaultManager.contentsOfDirectoryAtPathError(directory, null);
  if (!names || names.isNil()) return [];
  return ObjC.deepUnwrap(names).sort();
}

function sessionFiles(dataDir) {
  const root = dataDir + '/' + SESSIONS_DIR;
  const files = [];
  for (const account of childNames(root)) {
    for (const organization of childNames(root + '/' + account)) {
      const directory = root + '/' + account + '/' + organization;
      for (const name of childNames(directory)) {
        if (SESSION_FILE_PATTERN.test(name)) files.push({path: directory + '/' + name, stem: name.replace(/\.json$/, '')});
      }
    }
  }
  return files;
}

function trimSlashes(path) {
  return typeof path === 'string' ? path.replace(/\/+$/, '') : '';
}

function number(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function mergeSessions(existing, incoming) {
  if (!existing) return incoming;
  const newer = incoming.lastActive > existing.lastActive ? incoming : existing;
  return {
    archived: existing.archived && incoming.archived,
    starred: existing.starred || incoming.starred,
    kept: existing.kept || incoming.kept,
    lastActive: Math.max(existing.lastActive, incoming.lastActive),
    title: newer.title
  };
}

function register(index, key, session) {
  index[key] = mergeSessions(index[key], session);
}

function sessionIndex(dataDir) {
  const byId = {};
  const byPath = {};
  for (const file of sessionFiles(dataDir)) {
    const document = tryJson(file.path);
    if (!document || typeof document !== 'object') continue;
    const session = {
      archived: document.isArchived === true,
      starred: document.isStarred === true,
      kept: Boolean(document.keptDirtyWorktree),
      lastActive: number(document.lastActivityAt),
      title: typeof document.title === 'string' ? document.title : ''
    };
    register(byId, file.stem, session);
    if (typeof document.sessionId === 'string' && document.sessionId !== file.stem) register(byId, document.sessionId, session);
    const worktreePath = trimSlashes(document.worktreePath);
    if (worktreePath && (!byPath[worktreePath] || byPath[worktreePath].lastActive < session.lastActive)) byPath[worktreePath] = session;
  }
  return {byId, byPath};
}

function entriesOf(registry) {
  const worktrees = registry && registry.worktrees;
  if (Array.isArray(worktrees)) return worktrees.map((entry) => [entry && entry.name, entry]);
  if (worktrees && typeof worktrees === 'object') return Object.keys(worktrees).map((key) => [key, worktrees[key]]);
  return [];
}

function field(value) {
  const text = String(value === undefined || value === null ? '' : value).replace(CONTROL_CHARACTERS, ' ').trim();
  return text === '' ? EMPTY_FIELD : text;
}

function describe(key, entry, sessions) {
  const leasedBy = typeof entry.leasedBy === 'string' ? entry.leasedBy : '';
  const path = typeof entry.path === 'string' ? entry.path : '';
  const owner = leasedBy ? sessions.byId[leasedBy] : null;
  const session = owner || sessions.byPath[trimSlashes(path)] || null;
  const lastActive = Math.max(session ? session.lastActive : 0, number(entry.createdAt), number(entry.pooledAt));
  return {
    name: typeof entry.name === 'string' && entry.name ? entry.name : key,
    path,
    baseRepo: typeof entry.baseRepo === 'string' ? entry.baseRepo : '',
    branch: typeof entry.branch === 'string' ? entry.branch : '',
    leased: leasedBy !== '',
    session,
    owned: Boolean(owner),
    lastActive
  };
}

function line(item) {
  const session = item.session;
  return [
    field(item.name),
    field(item.path),
    field(item.baseRepo),
    field(item.branch),
    item.leased ? 1 : 0,
    item.owned ? 1 : 0,
    session && session.archived ? 1 : 0,
    session && session.kept ? 1 : 0,
    session && session.starred ? 1 : 0,
    item.lastActive,
    field(session ? session.title : '')
  ].join('\t');
}

function list(dataDir) {
  const registryPath = dataDir + '/' + REGISTRY_FILE;
  if (!fileExists(registryPath)) return '';
  const sessions = sessionIndex(dataDir);
  const items = entriesOf(readJson(registryPath))
    .filter(([, entry]) => entry && typeof entry === 'object')
    .map(([key, entry]) => describe(key, entry, sessions));
  items.sort((a, b) => a.lastActive - b.lastActive || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  return items.map(line).join('\n');
}

function run(argv) {
  const [dataDir] = argv;
  if (!dataDir) fail('usage: worktrees.js <data-dir>');
  return list(dataDir.replace(/\/+$/, ''));
}
