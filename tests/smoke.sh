#!/usr/bin/env bash
# Offline regression tests. Uses a mock SSH client; no network access.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/tunnel-test.XXXXXX)
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
export MOCK_LOG="$work/ssh.log"
mkdir -p "$HOME/.ssh" "$work/bin"
cat > "$work/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
set -eu
sock= op= arg=
while (( $# )); do
    case "$1" in
        -S) sock=$2; shift 2 ;;
        -O) op=$2; shift 2 ;;
        -L|-R) printf '%s %s\n' "$1" "$2" >> "$MOCK_LOG"; shift 2 ;;
        *) shift ;;
    esac
done
case "$op" in
    check) if [[ -f "$sock.mock" ]]; then echo 'Master running (pid=123)'; else echo 'Control socket connect: No such file or directory' >&2; exit 255; fi ;;
    exit) rm -f "$sock.mock" ;;
    '') printf 'CONNECT %s\n' "$sock" >> "$MOCK_LOG"; : > "$sock.mock" ;;
    *) exit 255 ;;
esac
MOCK
chmod +x "$work/bin/ssh"
export PATH="$work/bin:$PATH"
export TUNNEL_COLOR=never
unset NO_COLOR || :
tunnel() { "$BASH" "$root/tunnel" "$@"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "missing: $2"; }
assert_absent() { [[ "$1" != *"$2"* ]] || fail "unexpected: $2"; }
expect_rc() {
    local expected=$1 actual=0; shift
    "$@" > "$work/result" 2>&1 || actual=$?
    [[ "$actual" == "$expected" ]] || { cat "$work/result" >&2; fail "exit $actual (expected $expected)"; }
}
cp "$root/tunnels.toml" "$HOME/.ssh/tunnels.toml"
"$BASH" -n "$root/tunnel"
[[ $(tunnel --version) == 'tunnel 1.3.0' ]] || fail version
assert_contains "$(tunnel --help)" 'LOCAL and REMOTE'
# Check lookup by PATH, and fail clearly when SSH is missing.
mkdir "$work/limited"
for cmd in bash awk cat mkdir chmod rm rmdir sleep wc; do
    ln -s "$(command -v "$cmd")" "$work/limited/$cmd"
done
expect_rc 1 env PATH="$work/limited" "$root/tunnel" status
assert_contains "$(cat "$work/result")" 'missing dependency: ssh'
# Current configuration and compact table, without ANSI codes.
out=$(tunnel status)
assert_contains "$out" 'LOCAL'
assert_contains "$out" 'DOWN'
assert_contains "$out" 'gpu-server-proxy'
assert_absent "$out" 'gpu-server-proxy(gpu-server)'
assert_contains "$out" 'db(gateway)'
assert_contains "$out" '10.0.0.20:6379'
assert_absent "$out" $'\033'
[[ "$out" == "$(tunnel list)" ]] || fail 'list/status mismatch'
# Exact connection arguments, order, shared connection, and restart behavior.
: > "$MOCK_LOG"
tunnel connect gpu-server > /dev/null
expected=$(printf '%s\n' '-L 127.0.0.1:9010:127.0.0.1:9010' '-L 127.0.0.1:9011:127.0.0.1:9011' '-R 127.0.0.1:7898:127.0.0.1:7898' "CONNECT $HOME/.ssh/tunnels/gpu-server.sock")
[[ $(cat "$MOCK_LOG") == "$expected" ]] || fail 'wrong SSH arguments'
tunnel connect gpu-server > /dev/null
[[ $(cat "$MOCK_LOG") == "$expected" ]] || fail 'duplicate connection'
out=$(tunnel status gpu-server)
assert_contains "$out" UP
assert_contains "$out" '->'
assert_contains "$out" '<-'
assert_absent "$out" DOWN
# Header positions and continuation rows: each rendered column begins at the header offset.
printf '%s\n' "$out" | awk 'NR==1 { st=index($0,"ST"); loc=index($0,"LOCAL"); dir=index($0,"DIR"); rem=index($0,"REMOTE"); next } NR==2 { if(substr($0,st,2)!="UP") exit 1 } NR>2 { if(substr($0,1,st-1) ~ /[^ ]/ || substr($0,st,loc-st) ~ /[^ ]/) exit 1 } NR>1 { if(substr($0,dir,2)!="->" && substr($0,dir,2)!="<-") exit 1; if(substr($0,loc,1)!~/[0-9]/ || substr($0,rem,1)!~/[0-9]/) exit 1 } END { if(NR!=4) exit 1 }' || fail 'column alignment'
colored=$(TUNNEL_COLOR=always tunnel status gpu-server)
assert_contains "$colored" $'\033[32mUP\033[0m'
assert_contains "$colored" $'\033[36m->\033[0m'
assert_contains "$colored" $'\033[34m<-\033[0m'
plain=$(printf '%s\n' "$colored" | awk '{gsub(/\033\[[0-9;]*m/, ""); print}')
[[ "$plain" == "$out" ]] || fail 'color changed column alignment'
tunnel restart gpu-server >/dev/null
assert_contains "$(tunnel status gpu-server)" UP
tunnel disconnect gpu-server >/dev/null
assert_contains "$(tunnel status gpu-server)" DOWN
# Legacy configuration, cross-host and IPv6 endpoints.
tunnel connect db redis >/dev/null
assert_contains "$(tunnel status db)" UP
assert_contains "$(tunnel status redis)" UP
tunnel disconnect all >/dev/null
cat >> "$HOME/.ssh/tunnels.toml" <<'TOML'

[tunnels.ipv6]
host = "gateway"
type = "local"
local = "[::1]:8080"
remote = "[2001:db8::1]:80"
TOML
out=$(tunnel status ipv6)
assert_contains "$out" '[::1]:8080'
assert_contains "$out" '[2001:db8::1]:80'
expect_rc 2 tunnel connect db nonexistent
assert_contains "$(tunnel status db)" DOWN
expect_rc 2 tunnel connect
# Reject malformed config before contacting SSH.
printf '\n[tunnels.invalid]\nhost = "gateway"\ntype = "local"\nlocal = "127.0.0.1:99999"\nremote = "127.0.0.1:80"\n' >> "$HOME/.ssh/tunnels.toml"
expect_rc 2 tunnel status
assert_contains "$(cat "$work/result")" 'invalid or missing endpoint'
printf 'PASS: portable smoke tests (mock SSH)\n'
