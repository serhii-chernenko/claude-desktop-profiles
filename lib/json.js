ObjC.import('Foundation');
ObjC.import('stdlib');
ObjC.import('stdio');

const BACKUP_SUFFIX = '.claude-profiles.bak';
const TEMPORARY_SUFFIX = '.claude-profiles.tmp';
const NEW_FILE_MODE = 0o600;

function fail(message, code) {
  const data = $(message + '\n').dataUsingEncoding($.NSUTF8StringEncoding);
  $.NSFileHandle.fileHandleWithStandardError.writeData(data);
  $.exit(code || 1);
}

function fileExists(path) {
  return $.NSFileManager.defaultManager.fileExistsAtPath(path);
}

function readJson(path, required) {
  if (!fileExists(path)) {
    if (required) fail('json.js: not found: ' + path);
    return {};
  }
  const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  if (!text || text.isNil()) fail('json.js: cannot read ' + path);
  try {
    return JSON.parse(ObjC.unwrap(text));
  } catch (error) {
    fail('json.js: invalid JSON in ' + path + ': ' + error.message);
  }
}

function backup(path) {
  if (!fileExists(path)) return;
  const manager = $.NSFileManager.defaultManager;
  const target = path + BACKUP_SUFFIX;
  if (fileExists(target)) manager.removeItemAtPathError(target, null);
  if (!manager.copyItemAtPathToPathError(path, target, null)) fail('json.js: cannot back up ' + path);
}

function modeOf(path) {
  if (!fileExists(path)) return NEW_FILE_MODE;
  const attributes = $.NSFileManager.defaultManager.attributesOfItemAtPathError(path, null);
  if (!attributes || attributes.isNil()) fail('json.js: cannot read the permissions of ' + path);
  return ObjC.unwrap(attributes.objectForKey('NSFilePosixPermissions')) & 0o7777;
}

function writeJson(path, value) {
  const manager = $.NSFileManager.defaultManager;
  const mode = modeOf(path);
  const temporary = path + TEMPORARY_SUFFIX;
  backup(path);
  if (fileExists(temporary)) manager.removeItemAtPathError(temporary, null);
  const data = $(JSON.stringify(value, null, 2) + '\n').dataUsingEncoding($.NSUTF8StringEncoding);
  const attributes = $({NSFilePosixPermissions: mode});
  if (!manager.createFileAtPathContentsAttributes(temporary, data, attributes)) fail('json.js: cannot write ' + temporary);
  if ($.rename(temporary, path) !== 0) fail('json.js: cannot move ' + temporary + ' to ' + path);
}

function projectsOf(document) {
  if (!document.projects || typeof document.projects !== 'object') document.projects = {};
  return document.projects;
}

function transfer(source, target, key, removeFromSource) {
  if (source === target) fail('json.js: source and target are the same file');
  const sourceDocument = readJson(source, true);
  const sourceProjects = projectsOf(sourceDocument);
  if (!Object.prototype.hasOwnProperty.call(sourceProjects, key)) fail('json.js: no projects entry for ' + key + ' in ' + source, 3);
  const targetDocument = readJson(target, false);
  projectsOf(targetDocument)[key] = sourceProjects[key];
  writeJson(target, targetDocument);
  if (removeFromSource) {
    delete sourceProjects[key];
    writeJson(source, sourceDocument);
  }
  return (removeFromSource ? 'moved ' : 'copied ') + key;
}

function run(argv) {
  const [command, first, second, third] = argv;
  switch (command) {
    case 'get': {
      if (!first || !second) fail('usage: json.js get <file> <project-key>');
      const projects = projectsOf(readJson(first, true));
      if (!Object.prototype.hasOwnProperty.call(projects, second)) fail('json.js: no projects entry for ' + second, 3);
      return JSON.stringify(projects[second], null, 2);
    }
    case 'keys':
      if (!first) fail('usage: json.js keys <file>');
      return Object.keys(projectsOf(readJson(first, true))).join('\n');
    case 'copy':
    case 'move':
      if (!first || !second || !third) fail('usage: json.js ' + command + ' <source-file> <target-file> <project-key>');
      return transfer(first, second, third, command === 'move');
    default:
      fail('usage: json.js get <file> <key> | keys <file> | copy|move <source-file> <target-file> <key>');
  }
}
