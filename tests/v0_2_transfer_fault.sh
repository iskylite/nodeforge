#!/usr/bin/env bash
# v0.2 initrd rootfs transfer fault-injection validation.
#
# Exercises the real initrd download contract (strict HEAD + chunked Range with
# If-Range + per-chunk metadata validation + final SHA-512) against a fault-
# injecting HTTP/1.0 server. Mirrors src/initrd.zig downloadRootfs / src/initrd/
# download.zig parseHead|validateRange semantics. Verifies fail-closed on:
#   - stream break (server closes mid-chunk)
#   - ETag drift (server serves different content/ETag than HEAD promised)
#   - content corruption (valid headers, flipped body bytes)
# and a clean baseline that passes end-to-end.
#
# Runs on Linux (curl + python3). Validation logic replicates the Zig download
# module; the Zig unit tests cover the exact parseHead/validateRange code.
set -euo pipefail

work=${TMPDIR:-/tmp}/nodeforge-v02-fault-$$
port=$((18100 + ($$ % 999)))
rootfs_size=$((4 * 1024 * 1024 + 13)) # >1 chunk to exercise Range boundaries
chunk=4194304

cleanup() { [ -n "${srv_pid:-}" ] && kill "$srv_pid" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$work"

cat > "$work/server.py" <<'PY'
import http.server, socketserver, os, sys, hashlib, threading, time
WORK, PORT, SIZE = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
data = os.urandom(SIZE)
open(os.path.join(WORK, "rootfs.bin"), "wb").write(data)
sha = hashlib.sha512(data).hexdigest()
open(os.path.join(WORK, "sha512"), "w").write(sha)
open(os.path.join(WORK, "size"), "w").write(str(SIZE))
FAULT = os.path.join(WORK, "fault")
open(FAULT, "w").write("none")
DRIFTED = os.urandom(SIZE)
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    server_version = "nf"
    sys_version = ""
    def log_message(self, *a): pass
    def _fault(self):
        try: return open(FAULT).read().strip()
        except: return "none"
    def _body_etag(self):
        b = DRIFTED if self._fault() == "drift" else data
        return b, '"' + hashlib.sha512(b).hexdigest() + '"'
    def do_HEAD(self):
        b, et = self._body_etag()
        self.send_response(200)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("ETag", et)
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
    def do_GET(self):
        rng = self.headers.get("Range"); ifr = self.headers.get("If-Range")
        b, et = self._body_etag()
        if rng and rng.startswith("bytes="):
            span = rng[6:].split("-"); start, end = int(span[0]), int(span[1])
            if ifr and ifr != et:
                self.send_response(200); self.send_header("Content-Length", str(len(b)))
                self.send_header("ETag", et); self.end_headers(); self.wfile.write(b); return
            f = self._fault()
            if f == "break":
                self.send_response(206); self.send_header("Content-Range", "bytes %d-%d/%d" % (start,end,len(b)))
                self.send_header("Content-Length", str(end-start+1)); self.send_header("ETag", et); self.end_headers()
                self.wfile.write(b[start:start+(end-start+1)//2]); self.wfile.flush(); return
            piece = b[start:end+1]
            if f == "corrupt" and end == len(b)-1:
                piece = bytearray(piece); piece[0] ^= 0xFF; piece = bytes(piece)
            self.send_response(206); self.send_header("Content-Range", "bytes %d-%d/%d" % (start,end,len(b)))
            self.send_header("Content-Length", str(len(piece))); self.send_header("ETag", et); self.end_headers(); self.wfile.write(piece); return
        self.send_response(200); self.send_header("Content-Length", str(len(b)))
        self.send_header("ETag", et); self.end_headers(); self.wfile.write(b)
class TS(socketserver.TCPServer):
    allow_reuse_address = True; daemon_threads = True
srv = TS(("127.0.0.1", PORT), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
open(os.path.join(WORK, "ready"), "w").write("1")
while os.path.exists(os.path.join(WORK, "ready")): time.sleep(0.2)
srv.shutdown()
PY

python3 "$work/server.py" "$work" "$port" "$rootfs_size" >/dev/null 2>&1 &
srv_pid=$!
for _ in $(seq 1 50); do [ -f "$work/ready" ] && break; sleep 0.1; done
[ -f "$work/ready" ] || { echo "server failed to start" >&2; exit 1; }

base="http://127.0.0.1:$port/rootfs.bin"
expected_sha=$(cat "$work/sha512")
expected_size=$(cat "$work/size")
set_fault() { echo "$1" > "$work/fault"; }

# Replicates download.parseHead: 200, Content-Length==expected, ETag==expected, Accept-Ranges=bytes.
# Exit 0 = valid, non-zero = rejected (fail-closed). stderr carries the reason.
check_head() {
    python3 "$work/check_head.py" "$1" "$expected_size" "\"$expected_sha\""
}
cat > "$work/check_head.py" <<'PY'
import sys
try:
    h = open(sys.argv[1]).read(); size = int(sys.argv[2]); etag = sys.argv[3]
    block = h[h.rfind("HTTP/"):]
    lines = block.split("\n")
    parts = lines[0].split()
    status = parts[1] if len(parts) > 1 else "0"
    assert status == "200", f"head status {status}"
    def hdr(n):
        for ln in lines[1:]:
            ln = ln.strip()
            if ln.lower().startswith(n.lower() + ":"): return ln.split(":", 1)[1].strip()
        return None
    cl = hdr("Content-Length"); ar = hdr("Accept-Ranges"); et = hdr("ETag")
    assert cl and int(cl) == size, f"Content-Length {cl} != {size}"
    assert et == etag, f"ETag {et} != {etag}"
    assert ar and ar.lower() == "bytes", f"Accept-Ranges {ar}"
except AssertionError as e:
    print("head-check:", e, file=sys.stderr); sys.exit(1)
PY
# Replicates download.validateRange: 206, ETag==expected, Content-Range==bytes s-e/t, Content-Length==e-s+1.
check_range() {
    python3 "$work/check_range.py" "$1" "$2" "$3" "$4" "\"$expected_sha\""
}
cat > "$work/check_range.py" <<'PY'
import sys
try:
    h = open(sys.argv[1]).read(); s = int(sys.argv[2]); e = int(sys.argv[3]); t = int(sys.argv[4]); etag = sys.argv[5]
    block = h[h.rfind("HTTP/"):]
    lines = block.split("\n")
    parts = lines[0].split()
    status = parts[1] if len(parts) > 1 else "0"
    assert status == "206", f"range status {status} != 206"
    def hdr(n):
        for ln in lines[1:]:
            ln = ln.strip()
            if ln.lower().startswith(n.lower() + ":"): return ln.split(":", 1)[1].strip()
        return None
    et = hdr("ETag"); cr = hdr("Content-Range"); cl = hdr("Content-Length")
    assert et == etag, f"ETag {et} != {etag}"
    assert cr == f"bytes {s}-{e}/{t}", f"Content-Range {cr}"
    assert cl and int(cl) == e - s + 1, f"Content-Length {cl} != {e-s+1}"
except AssertionError as ex:
    print("range-check:", ex, file=sys.stderr); sys.exit(1)
PY

# download: HEAD + chunked Range w/ If-Range + SHA-512. 0 = ok, non-zero = fail-closed.
download() {
    curl -fsS --max-time 15 -I -H "Accept-Encoding: identity" -D "$work/head.h" -o /dev/null "$base" || return 1
    check_head "$work/head.h" 2>/dev/null || return 1
    : > "$work/part"; local off=0
    while (( off < expected_size )); do
        local end=$(( expected_size - 1 < off + chunk - 1 ? expected_size - 1 : off + chunk - 1 ))
        curl -fsS --max-time 15 -H "Accept-Encoding: identity" \
            -H "Range: bytes=$off-$end" -H "If-Range: \"$expected_sha\"" \
            -D "$work/range.h" -o "$work/chunk" "$base" || return 2
        check_range "$work/range.h" "$off" "$end" "$expected_size" 2>/dev/null || return 3
        local got=$(stat -c%s "$work/chunk"); (( got == end - off + 1 )) || return 4
        cat "$work/chunk" >> "$work/part"; off=$(( end + 1 ))
    done
    sha512sum "$work/part" | cut -d' ' -f1 > "$work/got_sha"; return 0
}

echo "=== baseline: clean transfer ==="
set_fault none
if download && [ "$(cat "$work/got_sha")" = "$expected_sha" ]; then
    echo "PASS: clean HEAD/Range/SHA-512 verified"
else
    echo "FAIL: clean transfer did not verify" >&2; exit 1
fi

echo "=== ETag drift (content/ETag differs from HEAD promise) ==="
set_fault drift
if download; then echo "FAIL: drift accepted" >&2; exit 1
else echo "PASS: ETag drift rejected (fail-closed)"; fi

echo "=== content corruption (valid headers, flipped final-chunk byte) ==="
set_fault corrupt
if download; then
    if [ "$(cat "$work/got_sha")" = "$expected_sha" ]; then
        echo "FAIL: corruption passed SHA-512" >&2; exit 1
    fi
    echo "PASS: content corruption rejected by SHA-512 (fail-closed)"
else
    echo "PASS: content corruption rejected (fail-closed)"
fi

echo "=== stream break mid-chunk ==="
set_fault break
if download; then echo "FAIL: stream break accepted" >&2; exit 1
else echo "PASS: stream break rejected (fail-closed)"; fi

rm -f "$work/ready"
echo "v0.2 transfer fault-injection validation passed"
