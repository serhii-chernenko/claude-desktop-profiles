DEFAULT_SIGNING_IDENTITY="Claude Profiles Signing"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

identity_in_keychain() {
  security find-certificate -c "$1" "$LOGIN_KEYCHAIN" >/dev/null 2>&1
}

identity_can_sign() {
  local probe_dir probe
  probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/claude-profiles-sign-probe.XXXXXX") || return 1
  probe="$probe_dir/probe"
  cp /usr/bin/true "$probe"
  local signed=1
  codesign --force --sign "$1" --timestamp=none "$probe" </dev/null >/dev/null 2>&1 && signed=0
  rm -rf "$probe_dir"
  return $signed
}

resolve_signing_identity() {
  if [[ -n ${SIGNING_IDENTITY:-} ]]; then
    print -r -- "$SIGNING_IDENTITY"
  elif identity_in_keychain "$DEFAULT_SIGNING_IDENTITY" && identity_can_sign "$DEFAULT_SIGNING_IDENTITY"; then
    print -r -- "$DEFAULT_SIGNING_IDENTITY"
  else
    print -- -
  fi
}

identity_sha1() {
  security find-certificate -c "$1" -Z "$LOGIN_KEYCHAIN" 2>/dev/null | awk '/^SHA-1 hash:/ { print $3; exit }'
}

identity_is_self_signed() {
  local summary subject issuer
  summary=$(security find-certificate -c "$1" -p "$LOGIN_KEYCHAIN" 2>/dev/null | openssl x509 -noout -subject -issuer 2>/dev/null) || return 1
  subject=$(print -r -- "$summary" | sed -n 's/^subject= *//p')
  issuer=$(print -r -- "$summary" | sed -n 's/^issuer= *//p')
  [[ -n $subject && $subject == "$issuer" ]]
}
