ObjC.import('Foundation');
ObjC.import('stdlib');

const INTEGRITY_ALGORITHM = 'SHA256';
const INTEGRITY_BLOCK_SIZE = 4194304;
const BOOT_MARKER = 'const CDP_PROFILE = ';

function fail(message, code) {
  const data = $(message + '\n').dataUsingEncoding($.NSUTF8StringEncoding);
  $.NSFileHandle.fileHandleWithStandardError.writeData(data);
  $.exit(code || 1);
}

function readText(path) {
  const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  if (!text || text.isNil()) fail('asar.js: cannot read ' + path);
  return ObjC.unwrap(text);
}

function writeText(path, text) {
  if (!$(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)) fail('asar.js: cannot write ' + path);
}

function readJson(path) {
  try {
    return JSON.parse(readText(path));
  } catch (error) {
    fail('asar.js: invalid JSON in ' + path + ': ' + error.message);
  }
}

function lookup(header, entryPath) {
  let node = header;
  for (const part of entryPath.replace(/^\.\//, '').split('/')) {
    if (!part) continue;
    if (!node.files || !Object.prototype.hasOwnProperty.call(node.files, part)) return null;
    node = node.files[part];
  }
  return node;
}

function describeEntry(headerPath, entryPath) {
  const node = lookup(readJson(headerPath), entryPath);
  if (!node) fail('asar.js: no entry ' + entryPath, 3);
  if (node.files) fail('asar.js: ' + entryPath + ' is a directory', 4);
  if (node.link) fail('asar.js: ' + entryPath + ' is a link', 4);
  const integrity = node.integrity || {};
  return [
    node.offset === undefined ? '-' : String(node.offset),
    String(node.size),
    integrity.algorithm || '-',
    integrity.blockSize === undefined ? '-' : String(integrity.blockSize),
    integrity.hash || '-',
    Array.isArray(integrity.blocks) ? integrity.blocks.join(',') || '-' : '-',
    node.unpacked ? '1' : '0',
  ].join('\t');
}

function patchPackage(source, target, bootName) {
  const document = readJson(source);
  if (typeof document.main !== 'string' || !document.main) fail('asar.js: package.json has no main', 3);
  if (document.main === bootName || document.cdpOriginalMain !== undefined) fail('asar.js: package.json is already patched', 4);
  if (document.type === 'module' || document.main.endsWith('.mjs')) fail('asar.js: the app is an ES module; the boot file cannot load it', 3);
  const original = document.main;
  document.main = bootName;
  document.cdpOriginalMain = original;
  writeText(target, JSON.stringify(document, null, 2) + '\n');
  return original;
}

function bootSource(profile) {
  return [
    '"use strict";',
    BOOT_MARKER + JSON.stringify(profile) + ';',
    'const fs = require("fs");',
    'const path = require("path");',
    'const Module = require("module");',
    'const { app } = require("electron");',
    '',
    'function ownsScheme(scheme) {',
    '  const name = String(scheme || "").toLowerCase();',
    '  return name === CDP_PROFILE.scheme || name.startsWith(CDP_PROFILE.scheme + "-");',
    '}',
    '',
    'function keepSchemeUnclaimed(method, ownedResult) {',
    '  const original = app[method];',
    '  if (typeof original !== "function") return;',
    '  try {',
    '    app[method] = function (scheme, ...rest) {',
    '      if (ownsScheme(scheme)) return ownedResult;',
    '      return original.call(app, scheme, ...rest);',
    '    };',
    '  } catch (error) {',
    '    console.warn("cdp-boot: could not wrap app." + method + ": " + error.message);',
    '  }',
    '}',
    '',
    'function setPathIfKnown(name, value) {',
    '  try {',
    '    app.setPath(name, value);',
    '  } catch (error) {',
    '    console.warn("cdp-boot: could not set path " + name + ": " + error.message);',
    '  }',
    '}',
    '',
    'try {',
    '  fs.mkdirSync(CDP_PROFILE.dataDir, { recursive: true, mode: 0o700 });',
    '} catch (error) {',
    '  console.warn("cdp-boot: could not create " + CDP_PROFILE.dataDir + ": " + error.message);',
    '}',
    'app.setPath("userData", CDP_PROFILE.dataDir);',
    'setPathIfKnown("sessionData", CDP_PROFILE.dataDir);',
    'app.setPath("logs", path.join(CDP_PROFILE.dataDir, "Logs"));',
    'app.setPath("crashDumps", path.join(CDP_PROFILE.dataDir, "Crashpad"));',
    'app.commandLine.appendSwitch("user-data-dir", CDP_PROFILE.dataDir);',
    'if (CDP_PROFILE.configDir) process.env.CLAUDE_CONFIG_DIR ??= CDP_PROFILE.configDir;',
    'keepSchemeUnclaimed("setAsDefaultProtocolClient", true);',
    'keepSchemeUnclaimed("removeAsDefaultProtocolClient", true);',
    'keepSchemeUnclaimed("isDefaultProtocolClient", false);',
    'Module._load(path.join(__dirname, CDP_PROFILE.originalMain), null, true);',
    '',
  ].join('\n');
}

function writeBoot(target, version, dataDir, configDir, originalMain, scheme) {
  if (!/^[0-9]+$/.test(version || '')) fail('asar.js: invalid boot version "' + version + '"');
  if (!dataDir || dataDir[0] !== '/') fail('asar.js: the data dir must be an absolute path');
  if (configDir && configDir !== '-' && configDir[0] !== '/') fail('asar.js: the config dir must be an absolute path or -');
  if (!originalMain || originalMain[0] === '/' || originalMain.split('/').includes('..')) fail('asar.js: invalid original main "' + originalMain + '"');
  if (!/^[a-z][a-z0-9+.-]*$/.test(scheme || '')) fail('asar.js: invalid URL scheme "' + scheme + '"');
  writeText(target, bootSource({
    version: Number(version),
    dataDir: dataDir,
    configDir: configDir && configDir !== '-' ? configDir : null,
    originalMain: originalMain,
    scheme: scheme,
  }));
  return target;
}

function bootInfo(path) {
  const line = readText(path).split('\n').find((candidate) => candidate.startsWith(BOOT_MARKER));
  if (!line) fail('asar.js: no profile block in ' + path, 3);
  let profile;
  try {
    profile = JSON.parse(line.slice(BOOT_MARKER.length).replace(/;\s*$/, ''));
  } catch (error) {
    fail('asar.js: invalid profile block in ' + path + ': ' + error.message, 3);
  }
  return [profile.version, profile.dataDir || '-', profile.configDir || '-', profile.originalMain || '-'].join('\t');
}

function addEntries(source, target, dataSize, triples) {
  if (!/^[0-9]+$/.test(dataSize || '')) fail('asar.js: invalid data size "' + dataSize + '"');
  if (triples.length === 0 || triples.length % 3 !== 0) fail('usage: asar.js add <header> <out> <data-size> <name> <size> <sha256>...');
  const header = readJson(source);
  if (!header.files || typeof header.files !== 'object') fail('asar.js: header has no files');
  let offset = Number(dataSize);
  for (let i = 0; i < triples.length; i += 3) {
    const [name, size, hash] = triples.slice(i, i + 3);
    if (!name || name.includes('/')) fail('asar.js: entries are added at the archive root only: ' + name);
    if (!/^[0-9]+$/.test(size) || Number(size) > INTEGRITY_BLOCK_SIZE) fail('asar.js: invalid size for ' + name + ': ' + size);
    if (!/^[0-9a-f]{64}$/.test(hash)) fail('asar.js: invalid sha256 for ' + name);
    header.files[name] = {
      size: Number(size),
      offset: String(offset),
      integrity: { algorithm: INTEGRITY_ALGORITHM, hash: hash, blockSize: INTEGRITY_BLOCK_SIZE, blocks: [hash] },
    };
    offset += Number(size);
  }
  writeText(target, JSON.stringify(header));
  return String(offset);
}

function run(argv) {
  const [command, ...rest] = argv;
  switch (command) {
    case 'entry':
      if (rest.length !== 2) fail('usage: asar.js entry <header.json> <path>');
      return describeEntry(rest[0], rest[1]);
    case 'main': {
      if (rest.length !== 1) fail('usage: asar.js main <package.json>');
      const main = readJson(rest[0]).main;
      if (typeof main !== 'string' || !main) fail('asar.js: package.json has no main', 3);
      return main;
    }
    case 'package':
      if (rest.length !== 3) fail('usage: asar.js package <package.json> <out> <boot-name>');
      return patchPackage(rest[0], rest[1], rest[2]);
    case 'boot':
      if (rest.length !== 6) fail('usage: asar.js boot <out> <version> <data-dir> <config-dir|-> <original-main> <scheme>');
      return writeBoot(...rest);
    case 'boot-info':
      if (rest.length !== 1) fail('usage: asar.js boot-info <boot-file>');
      return bootInfo(rest[0]);
    case 'add':
      if (rest.length < 6) fail('usage: asar.js add <header> <out> <data-size> <name> <size> <sha256>...');
      return addEntries(rest[0], rest[1], rest[2], rest.slice(3));
    default:
      fail('usage: asar.js entry | main | package | boot | boot-info | add');
  }
}
