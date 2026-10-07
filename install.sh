#!/usr/bin/env bash
# One-command installer for RST AI Copilot for Prometheus.
#
#   curl -fsSL https://github.com/reallysec/RST-Prometheus-AI-Copilot/releases/latest/download/install.sh | sudo bash
#
# Options: --version <x.y.z> (default: the newest signed release)   --dir <path> (default below)
#          --mirror github|cn   github: GitHub Releases only; cn: China mirror (Tencent COS) first,
#                               GitHub second. Default: GitHub first, the China mirror when it fails.
#                               Same as env RST_MIRROR=github|cn.
#          --download-only   verify and save the archive in the current directory, deploy nothing
#                            (carry it to an air-gapped host and run deploy.sh there)
#
# Every edition is the same archive: without a license it runs as the Community Edition;
# importing a license in Settings -> License unlocks Professional or Enterprise in place.
# Every release is checked against its signed manifest (release-manifest.token, signed with
# the Reallysec release key embedded below): the archive must match the signed sha256, or
# nothing is installed. Without --version the newest signed release is installed (a release
# whose manifest is not uploaded yet, minutes after the build, is skipped with a message).
# Re-running it (a newer version) keeps .env and state/machine-id in the install directory.
set -euo pipefail

PRODUCT="RST AI Copilot for Prometheus"
STEM="RST-Prometheus-AI-Copilot"                     # archive: <STEM>-<version>.tar.gz
GH_REPO="reallysec/RST-Prometheus-AI-Copilot"
DIR="/opt/rst-prometheus-ai-copilot"
# China mirror (Tencent COS): <base>/rst-prometheus-ai-copilot/<version>/<file> and .../latest/VERSION.
# The bucket does not exist yet — this default is a PLACEHOLDER. Until it is replaced (or
# RST_COS_BASE is set) the mirror is skipped instead of trying a bogus host.
COS_PLACEHOLDER="https://rst-releases-XXXXXXXX.cos.ap-shanghai.myqcloud.com"
COS_BASE="${RST_COS_BASE:-$COS_PLACEHOLDER}"
COS_PREFIX="rst-prometheus-ai-copilot"
# GitHub endpoints; overridable so the tests can run offline against file:// trees.
# Nothing here is trusted: only the signature below is.
GH_BASE="${RST_GITHUB_BASE:-https://github.com/$GH_REPO/releases}"
GH_API="${RST_GITHUB_API:-https://api.github.com/repos/$GH_REPO/releases?per_page=10}"
TOKEN="release-manifest.token"
# ponytail: 许可服务器上的产品 ID 未定(PORT-PLAN 待确认),先与 license_state.PRODUCT_ID 保持一致。
APP_ID="rst_prometheus_ai_copilot"
# Release signing key, public half (same as app/keys/license_public.pem and the key in
# deploy/rst-update.sh). RELEASE_PUBKEY (a PEM path) replaces it for tests; `sudo bash`
# drops the caller's environment, so a customer install uses the embedded key.
RELEASE_PUBKEY="${RELEASE_PUBKEY:-}"
EMBEDDED_PUBKEY='-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAiU03kOJ0131hcGVTInWP
qPL0fBGi0jnVnAlbxRAkQ6djLTaXqGrFA8+5S4VgYjP9/yC/3cyiaDcgTPE1kPCk
G3f9uXCwkLAkB+9udK4N5XGRPOrI3407G420iiYconuAxB9s2vOwrc/TFcCNBKzF
xnYK6CYszr7fIPWeYqyIa6UMjHhVI+1V+AGR3XynuyPLeRu+TYs0757IVG5J1MWN
wcXbhb1ivDMun3PZbH2H6lGQamsuEAe1CQUzlSyWCM6BFSUMMrMWMiy8FdyQpJ5R
Hovamqo8OxHDTadB2BhWEttu2mojlzS9eQO0c1zEMb+nxK7ilzoTTVJ8pAJd+JZI
k3Dk6CF0f1qAlby0CjlWZpSkvrnL51rq+LxkwknLapRjkcY/k5k2je7oU8d8Yk1J
JKXPMsm1kYz3inmhx+PuKdmUsHu0Cg4GyALwMPesB7jBQecxgR39/ve5b8Vtksql
38KuC/bQMWYtU4CJTze6g9flfbCJB0wT6MZdR/KmNeKHAgMBAAE=
-----END PUBLIC KEY-----'

VERSION=""; DOWNLOAD_ONLY=0; MIRROR="${RST_MIRROR:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --download-only) DOWNLOAD_ONLY=1; shift ;;
    --version) VERSION="${2#v}"; shift 2 ;;
    --dir)     DIR="${2:?}"; shift 2 ;;
    --mirror)  MIRROR="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0" 2>/dev/null || true; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

case "$MIRROR" in
  "")     ORDER="github cn" ;;
  github) ORDER="github" ;;
  cn)     ORDER="cn github" ;;
  *) fail "--mirror must be github or cn" ;;
esac
[ -z "$VERSION" ] || printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+)*$' || fail "bad --version: $VERSION"

# ── preflight ────────────────────────────────────────────────────────────────
for c in curl tar sha256sum base64; do command -v "$c" >/dev/null || fail "missing command: $c"; done
command -v openssl >/dev/null || fail "openssl is required to verify the release signature. \
Install it first: apt-get install -y openssl (Debian/Ubuntu) or yum install -y openssl (RHEL/CentOS)."
if [ "$DOWNLOAD_ONLY" = 0 ]; then
  [ "$(uname -s)" = Linux ] || fail "Linux only."
  [ "$(id -u)" = 0 ] || fail "run as root: pipe to 'sudo bash'."
  command -v docker >/dev/null || fail "Docker Engine 24+ is required. Install it first, e.g.: curl -fsSL https://get.docker.com | sh"
  docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required (the docker compose plugin)."
  [ -r /dev/tty ] || fail "deploy.sh asks questions; run this from an interactive terminal."
fi

# Scratch space for the manifest (and, when installing, the archive).
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
if [ -n "$RELEASE_PUBKEY" ]; then cp "$RELEASE_PUBKEY" "$WORK/pub.pem"
else printf '%s\n' "$EMBEDDED_PUBKEY" > "$WORK/pub.pem"; fi

# A stalled GitHub download (common from mainland China) counts as a failure: give up
# below 10 KB/s for 30 s so the mirror gets its turn.
CURL=(curl -fL --retry 2 --connect-timeout 15 --speed-limit 10240 --speed-time 30)

# Latest version from the /releases/latest redirect (no API call, no rate limit).
github_latest() {
  local u; u="$("${CURL[@]}" -sS -o /dev/null -w '%{url_effective}' "$GH_BASE/latest" 2>/dev/null)" || return 1
  u="${u##*/}"
  case "$u" in v[0-9]*) printf '%s' "${u#v}" ;; *) return 1 ;; esac
}
cos_latest() { "${CURL[@]}" -sS "$COS_BASE/$COS_PREFIX/latest/VERSION" 2>/dev/null | tr -d ' \r\n'; }
# Recent release versions, newest first. Only called when the newest release is not
# signed yet (unauthenticated API, 60 calls/hour per IP).
# ponytail: prereleases are listed too; they are only tried when not newer than the latest.
github_versions() {
  "${CURL[@]}" -sS "$GH_API" 2>/dev/null | grep -o '"tag_name": *"v[0-9][0-9.]*"' | sed 's/.*"v//; s/"$//'
}
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }  # $1 > $2

dl_base() {  # src version
  case "$1" in
    github) printf '%s' "$GH_BASE/download/v$2" ;;
    cn)     printf '%s' "$COS_BASE/$COS_PREFIX/$2" ;;
  esac
}

# Fetch the signed manifest of <version> into $WORK/token. The mirror may not have it
# (it is uploaded after the build); GitHub's copy is then just as good: the signature
# is what is trusted, not the host.
fetch_token() {  # src version
  rm -f "$WORK/token"
  "${CURL[@]}" -sS -o "$WORK/token" "$(dl_base "$1" "$2")/$TOKEN" 2>/dev/null && return 0
  if [ "$1" = cn ] && "${CURL[@]}" -sS -o "$WORK/token" "$(dl_base github "$2")/$TOKEN" 2>/dev/null; then
    say "== $2: the China mirror has no $TOKEN; using the one on GitHub"; return 0
  fi
  rm -f "$WORK/token"; return 1
}

# Verify $WORK/token for <version>: signature, product, version. Sets SIGNED_SHA.
# Any failure exits: a bad manifest means someone is serving a forged release.
verify_token() {  # version
  local payload_b64 sig_b64 payload bad="$1: $TOKEN is malformed. Nothing was installed."
  IFS=. read -r payload_b64 sig_b64 _ < <(tr -d '\r\n' < "$WORK/token"; echo)
  [ -n "$payload_b64" ] && [ -n "$sig_b64" ] || fail "$bad"
  printf '%s' "$payload_b64" > "$WORK/payload"
  printf '%s' "$sig_b64" | base64 -d > "$WORK/sig" 2>/dev/null || fail "$bad"
  openssl dgst -sha256 -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:-2 \
    -verify "$WORK/pub.pem" -signature "$WORK/sig" "$WORK/payload" >/dev/null 2>&1 \
    || fail "release signature check FAILED for $1: it was not signed by Reallysec. Nothing was installed."
  payload="$(base64 -d < "$WORK/payload" 2>/dev/null)" || fail "$bad"
  printf '%s' "$payload" | grep -q "\"app_id\":\"$APP_ID\"" \
    || fail "$1: the signed manifest is for another product. Nothing was installed."
  printf '%s' "$payload" | grep -q "\"release_version\":\"$1\"" \
    || fail "the signed manifest fetched for $1 is for another version. Nothing was installed."
  SIGNED_SHA="$(printf '%s' "$payload" | grep -o '{[^{}]*"kind":"bundle"[^{}]*}' \
    | sed -n 's/.*"sha256":"\([0-9a-f]\{64\}\)".*/\1/p' | head -1)"
  [ -n "$SIGNED_SHA" ] || fail "$1: the signed manifest lists no delivery bundle. Nothing was installed."
}

# Pick the version to install from <src> and fetch its manifest into $WORK/token.
# A pinned --version must have one; otherwise the newest release is preferred, then the
# newest one that is already signed.
pick_version() {  # src -> sets V
  local latest="" c
  if [ -n "$VERSION" ]; then
    V="$VERSION"
    fetch_token "$1" "$V" && return 0
    say "== $V: no signed manifest ($TOKEN) via $1; a pinned version is never installed unsigned"
    return 1
  fi
  case "$1" in github) latest="$(github_latest)" || latest="" ;; cn) latest="$(cos_latest)" || latest="" ;; esac
  if [ -n "$latest" ]; then
    V="$latest"; fetch_token "$1" "$V" && return 0
    say "== $V is not signed yet (no $TOKEN; it is uploaded a few minutes after the build); trying older releases"
  fi
  for c in $(github_versions); do
    [ "$c" = "$latest" ] && continue
    [ -n "$latest" ] && newer "$c" "$latest" && continue
    V="$c"
    if fetch_token "$1" "$V"; then
      say "== installing $V, the newest signed release; re-run later to get a newer one once it is signed"
      return 0
    fi
    say "== $V is not signed yet (no $TOKEN); trying older releases"
  done
  return 1
}

# Download + verify from one source into the current directory. Returns non-zero when the
# source is unreachable (the caller tries the next one); exits on anything forged.
get_from() {  # github|cn
  local base actual
  if [ "$1" = cn ] && [ "$COS_BASE" = "$COS_PLACEHOLDER" ]; then
    say "== China mirror not configured yet (set RST_COS_BASE); skipping it"; return 1
  fi
  pick_version "$1" || return 1
  verify_token "$V"
  base="$(dl_base "$1" "$V")"
  ARCHIVE="$STEM-$V.tar.gz"
  say "== $PRODUCT $V: signed manifest OK; downloading from $base"
  # No .sha256 download: it comes from the same host as the archive, so it proves
  # nothing the signed sha256 doesn't.
  "${CURL[@]}" -o "$ARCHIVE" "$base/$ARCHIVE" || { rm -f "$ARCHIVE"; return 1; }
  actual="$(sha256sum "$ARCHIVE" | cut -d' ' -f1)"
  if [ "$actual" != "$SIGNED_SHA" ]; then
    rm -f "$ARCHIVE"
    fail "$ARCHIVE is not the signed release (sha256 $actual, signed $SIGNED_SHA); deleted it. Nothing was installed."
  fi
  say "== $ARCHIVE: sha256 matches the signed release"
  VERSION="$V"
}
fetch_bundle() {
  local s
  for s in $ORDER; do
    get_from "$s" && return 0
    say "== download from $s failed"
  done
  fail "could not download a signed release (tried: $ORDER). Check the version and the network."
}

if [ "$DOWNLOAD_ONLY" = 1 ]; then
  fetch_bundle
  say "== saved $PWD/$ARCHIVE; on the target host: tar xzf $ARCHIVE && cd $STEM-$VERSION && ./deploy.sh"
  exit 0
fi

cd "$WORK"
fetch_bundle
say "== $PRODUCT $VERSION -> $DIR"

# ── unpack into the fixed directory ──────────────────────────────────────────
# The archive carries no .env and no state/, so an existing install keeps both. Old image
# tars are removed first so deploy.sh loads only this version's images.
mkdir -p "$DIR"
rm -f "$DIR"/"$STEM"-images-*.tar
tar xzf "$ARCHIVE" -C "$DIR" --strip-components=1
say "== unpacked; starting deploy.sh"
cd "$DIR"
rm -rf "$WORK"   # exec skips the EXIT trap
exec ./deploy.sh </dev/tty
