ObjC.import('AppKit');
ObjC.import('CoreServices');
ObjC.import('stdlib');

const SET_TIMEOUT_SECONDS = 10;
const POLL_INTERVAL_SECONDS = 0.2;

function fail(message) {
  const data = $(message + '\n').dataUsingEncoding($.NSUTF8StringEncoding);
  $.NSFileHandle.fileHandleWithStandardError.writeData(data);
  $.exit(1);
}

function validScheme(scheme) {
  if (!/^[a-zA-Z][a-zA-Z0-9+.-]*$/.test(scheme || '')) fail('urlhandler.js: invalid URL scheme "' + scheme + '"');
  return scheme;
}

function currentHandler(scheme) {
  const url = $.NSURL.URLWithString(scheme + '://');
  const appURL = $.NSWorkspace.sharedWorkspace.URLForApplicationToOpenURL(url);
  if (!appURL || appURL.isNil()) return 'none';
  const bundle = $.NSBundle.bundleWithURL(appURL);
  if (!bundle || bundle.isNil()) return 'none';
  const identifier = ObjC.unwrap(bundle.bundleIdentifier);
  return identifier || 'none';
}

function sameId(left, right) {
  return String(left).toLowerCase() === String(right).toLowerCase();
}

function waitFor(scheme, bundleId) {
  const deadline = Date.now() + SET_TIMEOUT_SECONDS * 1000;
  while (Date.now() < deadline) {
    if (sameId(currentHandler(scheme), bundleId)) return true;
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(POLL_INTERVAL_SECONDS));
  }
  return sameId(currentHandler(scheme), bundleId);
}

function setWithLaunchServices(scheme, bundleId) {
  if (typeof $.LSSetDefaultHandlerForURLScheme !== 'function') return false;
  try {
    return $.LSSetDefaultHandlerForURLScheme($(scheme), $(bundleId)) === 0;
  } catch (error) {
    return false;
  }
}

function setWithWorkspace(scheme, bundleId) {
  const workspace = $.NSWorkspace.sharedWorkspace;
  const appURL = workspace.URLForApplicationWithBundleIdentifier(bundleId);
  if (!appURL || appURL.isNil()) fail('urlhandler.js: no application registered for ' + bundleId);
  if (typeof workspace.setDefaultApplicationAtURLToOpenURLsWithSchemeCompletionHandler !== 'function') return false;
  workspace.setDefaultApplicationAtURLToOpenURLsWithSchemeCompletionHandler(appURL, $(scheme), () => {});
  return true;
}

function setHandler(scheme, bundleId) {
  if (!bundleId) fail('usage: urlhandler.js set <scheme> <bundle-id>');
  if (sameId(currentHandler(scheme), bundleId)) return bundleId;
  if (setWithLaunchServices(scheme, bundleId) && waitFor(scheme, bundleId)) return bundleId;
  if (setWithWorkspace(scheme, bundleId) && waitFor(scheme, bundleId)) return bundleId;
  fail('urlhandler.js: could not make ' + bundleId + ' the handler for ' + scheme + '://');
}

function run(argv) {
  const command = argv[0];
  switch (command) {
    case 'get':
      return currentHandler(validScheme(argv[1]));
    case 'set':
      return setHandler(validScheme(argv[1]), argv[2]);
    default:
      fail('usage: urlhandler.js get <scheme> | set <scheme> <bundle-id>');
  }
}
