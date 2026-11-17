#!/bin/bash
# WS-Stunnel + WS-Dropbear setup (SSL/SNI + path routing handled by gomux)

set -e
clear
cd

echo "========================================="
echo "Installing WS-Stunnel + WS-Dropbear"
echo "========================================="

# ========== PART 1: Install WS-Stunnel & WS-SSH ==========


echo "[1/6] Installing WS-Stunnel & WS-Dropbear (Go)..."

# ---- Go source embedded in this script (sshws/main.go), built locally on the VPS ----
BUILD_DIR=/tmp/wsgo-build
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
cat > "$BUILD_DIR/main.go" <<'GOEOF'
// ws-dropbear (Go) - WebSocket/HTTP(101) -> TCP proxy
// Same behavior as the Python ws-dropbear in aaa-main:
//   - reads the first packet (HTTP payload), answers 101, relays to target
//   - X-Real-Host header selects the target (default 127.0.0.1:22)
//   - no X-Real-Host: auto-detect from first client bytes (OpenVPN -> 1194, else SSH)
//   - ANY payload works for OpenVPN, same as SSH: header names are case-insensitive,
//     extra HTTP packets after the 101 (split / multi-request payloads) are skipped,
//     bytes glued to the payload are kept, and an X-Real-Host that points at SSH (:22)
//     is overridden when the client really speaks OpenVPN
//   - raw OpenVPN (no HTTP payload) arriving on this port goes straight to 1194
//   - X-Split: reads one more packet and discards it
//   - PASS empty: only 127.0.0.1 / localhost targets allowed (else 403)
//   - PASS set: X-Pass header must match (else 400 WrongPass!)
//   - idle timeout 180s (Python: 60 x 3s)
//   - listens on bind:port, port can be positional ("ws-dropbear 2095") or -p
//
// Build:  GOOS=linux GOARCH=amd64 go build -ldflags "-s -w" -o ws-dropbear .
// Usage:  ws-dropbear 2095
//         ws-dropbear -b 0.0.0.0 -p 2095 -t 127.0.0.1:22

package main

import (
	"bytes"
	"errors"
	"flag"
	"log"
	"net"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

const (
	bufLen      = 4096 * 4
	idleTimeout = 180 * time.Second
	pass        = "" // X-Pass password (empty = only localhost targets allowed)
	response    = "HTTP/1.1 101 Switching Protocols\r\nContent-Length: 104857600000\r\n\r\n"
)

var (
	defaultHost = "127.0.0.1:22"
	ovpnHost    = "127.0.0.1:1194"
	sniffWait   = 1500 * time.Millisecond // how long to wait for the client's first tunnel bytes
)

const sniffMaxPackets = 8 // max extra HTTP packets skipped while waiting for the tunnel to start

func asciiLower(b []byte) []byte {
	o := make([]byte, len(b))
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			c += 32
		}
		o[i] = c
	}
	return o
}

// findHeader returns the value of "Name: value" (name is case-insensitive, space after
// the colon optional, line may end in CRLF, LF or end of packet), or "" if missing.
func findHeader(head []byte, name string) string {
	key := strings.ToLower(name) + ":"
	i := bytes.Index(asciiLower(head), []byte(key))
	if i == -1 {
		return ""
	}
	v := string(head[i+len(key):])
	if j := strings.IndexAny(v, "\r\n"); j != -1 {
		v = v[:j]
	}
	return strings.TrimSpace(v)
}

// looksOVPN: first bytes of an OpenVPN-over-TCP client: 2-byte length + opcode byte
// (opcode<<3|keyid, opcode 1..10 covers the hard resets). Text never starts like this.
func looksOVPN(b []byte) bool {
	if len(b) < 3 || b[0] > 0x04 || (b[0] == 0 && b[1] == 0) {
		return false
	}
	op := b[2] >> 3
	return op >= 1 && op <= 10
}

func isTextStart(c byte) bool {
	return c == '\r' || c == '\n' || c == '\t' || (c >= 0x20 && c < 0x7f)
}

// stripHTTP drops leading HTTP text (header blocks ending in a blank line) and returns what
// follows. Text without the blank line yet is dropped completely (its tail comes later).
// "SSH-" is NOT http text: it is returned untouched.
func stripHTTP(b []byte) []byte {
	for len(b) > 0 && isTextStart(b[0]) {
		if bytes.HasPrefix(b, []byte("SSH-")) || bytes.HasPrefix([]byte("SSH-"), b) {
			return b
		}
		end := -1
		if i := bytes.Index(b, []byte("\r\n\r\n")); i != -1 {
			end = i + 4
		}
		if i := bytes.Index(b, []byte("\n\n")); i != -1 && (end == -1 || i+2 < end) {
			end = i + 2
		}
		if end == -1 {
			return nil
		}
		b = b[end:]
	}
	return b
}

// sniffStart is called after the 101 was sent. It returns the first real tunnel bytes the
// client sends (OpenVPN handshake / "SSH-..." banner / anything binary), skipping extra
// HTTP packets of split payloads. Empty result = client stayed quiet (SSH waits for the
// server banner).
func sniffStart(c net.Conn, buf []byte) ([]byte, error) {
	pk := make([]byte, bufLen)
	for i := 0; i <= sniffMaxPackets; i++ {
		buf = stripHTTP(buf)
		if len(buf) >= 3 {
			return buf, nil
		}
		wait := sniffWait
		if len(buf) > 0 {
			wait = 400 * time.Millisecond // 1-2 bytes so far: just need a few more
		}
		c.SetReadDeadline(time.Now().Add(wait))
		m, err := c.Read(pk)
		if m > 0 {
			buf = append(buf, pk[:m]...)
		}
		if err != nil {
			if isTimeout(err) {
				return buf, nil
			}
			if len(buf) == 0 {
				return nil, err
			}
			return buf, nil
		}
	}
	return buf, nil
}

// isLocalTarget: true only if the host part is exactly "localhost" or a
// loopback IP (127.0.0.0/8, ::1). Prefix matching let hosts like
// "127.0.0.1.1.2.3.4.nip.io" through (open proxy).
func isLocalTarget(hostPort string) bool {
	host := hostPort
	if h, _, err := net.SplitHostPort(hostPort); err == nil {
		host = h
	} else {
		host = strings.Trim(hostPort, "[]")
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func isTimeout(err error) bool {
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}

// pipe copies src -> dst. Idle time is tracked across BOTH directions
// (shared "last"), so a download with a quiet upload is not cut.
func pipe(dst, src net.Conn, last *int64, done chan<- struct{}) {
	defer func() { done <- struct{}{} }()
	buf := make([]byte, bufLen)
	for {
		src.SetReadDeadline(time.Now().Add(5 * time.Second))
		n, err := src.Read(buf)
		if n > 0 {
			atomic.StoreInt64(last, time.Now().UnixNano())
			if _, werr := dst.Write(buf[:n]); werr != nil {
				return
			}
		}
		if err != nil {
			if isTimeout(err) {
				idle := time.Since(time.Unix(0, atomic.LoadInt64(last)))
				if idle < idleTimeout {
					continue
				}
			}
			return
		}
	}
}

func handle(c net.Conn) {
	defer c.Close()

	c.SetReadDeadline(time.Now().Add(15 * time.Second))
	buf := make([]byte, bufLen)
	n, err := c.Read(buf)
	if err != nil {
		return
	}
	first := buf[:n]

	// raw OpenVPN straight on this port (no HTTP payload, no 101)
	if looksOVPN(first) {
		d, err := net.DialTimeout("tcp", ovpnHost, 10*time.Second)
		if err != nil {
			log.Println("dial", ovpnHost, err)
			return
		}
		defer d.Close()
		d.Write(first)
		c.SetReadDeadline(time.Time{})
		var last int64
		atomic.StoreInt64(&last, time.Now().UnixNano())
		done := make(chan struct{}, 2)
		go pipe(d, c, &last, done)
		go pipe(c, d, &last, done)
		<-done
		return
	}

	hostPort := findHeader(first, "X-Real-Host")
	explicit := hostPort != ""
	if !explicit {
		hostPort = defaultHost
	}
	rawSSH := bytes.HasPrefix(first, []byte("SSH-"))

	// Sniff the client when the target is not pinned to something other than SSH:
	// no X-Real-Host, or X-Real-Host pointing at :22 (an SSH payload reused for OpenVPN).
	sniff := false
	if !rawSSH {
		if !explicit {
			sniff = true
		} else if _, p, err := net.SplitHostPort(hostPort); err == nil && (p == "22" || hostPort == defaultHost) {
			sniff = true
		}
	}

	// client bytes that arrived glued to the payload (after the blank line)
	var rest []byte
	if !rawSSH && len(first) > 0 && isTextStart(first[0]) {
		rest = stripHTTP(first)
	}

	if findHeader(first, "X-Split") != "" {
		c.Read(make([]byte, bufLen)) // discard the second packet (own buffer: first/rest alias buf)
	}

	if pass != "" {
		if findHeader(first, "X-Pass") != pass {
			c.Write([]byte("HTTP/1.1 400 WrongPass!\r\n\r\n"))
			return
		}
	} else if !isLocalTarget(hostPort) {
		c.Write([]byte("HTTP/1.1 403 Forbidden!\r\n\r\n"))
		return
	}

	if !strings.Contains(hostPort, ":") {
		hostPort += ":443" // Python default
	}

	var early []byte // client bytes read before the target was known
	if sniff {
		// Answer 101 first, then look at what the client sends next.
		// OpenVPN (tcp) client speaks first: 2-byte length + opcode.
		// SSH clients send "SSH-..." or stay quiet until the server banner.
		if _, err := c.Write([]byte(response)); err != nil {
			return
		}
		var serr error
		early, serr = sniffStart(c, rest)
		if serr != nil {
			return
		}
		if looksOVPN(early) {
			hostPort = ovpnHost
		}
	}

	d, err := net.DialTimeout("tcp", hostPort, 10*time.Second)
	if err != nil {
		log.Println("dial", hostPort, err)
		return
	}
	defer d.Close()

	if sniff {
		if len(early) > 0 {
			d.Write(early)
		}
	} else if rawSSH {
		// Client sent SSH directly (no HTTP payload): pass it through.
		d.Write(first)
	} else {
		if _, err := c.Write([]byte(response)); err != nil {
			return
		}
		if len(rest) > 0 { // tunnel bytes glued to the payload
			d.Write(rest)
		}
	}
	c.SetReadDeadline(time.Time{})

	var last int64
	atomic.StoreInt64(&last, time.Now().UnixNano())
	done := make(chan struct{}, 2)
	go pipe(d, c, &last, done)
	go pipe(c, d, &last, done)
	<-done // either side ended -> defers close both
}

func main() {
	bind := flag.String("b", "0.0.0.0", "bind address")
	port := flag.Int("p", 2095, "listen port")
	flag.StringVar(&defaultHost, "t", defaultHost, "default target host:port (used when no X-Real-Host)")
	flag.StringVar(&ovpnHost, "o", ovpnHost, "OpenVPN target host:port (auto-detected OpenVPN clients)")
	wait := flag.Int("w", 1500, "ms to wait for the client's first bytes after the 101 (OpenVPN/SSH detection)")
	flag.Parse()
	sniffWait = time.Duration(*wait) * time.Millisecond

	// positional port, e.g. "ws-dropbear 2095" (as used by ws-dropbear.service)
	if flag.NArg() > 0 {
		p, err := strconv.Atoi(flag.Arg(0))
		if err != nil {
			log.Fatal("invalid port: ", flag.Arg(0))
		}
		*port = p
	}

	addr := net.JoinHostPort(*bind, strconv.Itoa(*port))
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal(err)
	}
	defer ln.Close()
	log.Printf("ws-dropbear listening on %s (default target %s)", addr, defaultHost)

	for {
		c, err := ln.Accept()
		if err != nil {
			log.Println(err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go handle(c)
	}
}
GOEOF

GO_OK=0

# ---- Go compiler: tarball hosted in the GitHub release assets (no apt, no fallback) ----
# Intel/AMD (x86_64)
GO_TGZ_URL_AMD64="https://github.com/noelrubio143/aaa/releases/download/assets/go1.27.2.linux-amd64.tar.gz"
GO_TGZ_SHA256_AMD64="ecbadb99091a3f46e31f5f934b068b1864eafa7995211b39eaddf76996045fe5"   # sha256 of go1.27.2.linux-amd64.tar.gz (https://go.dev/dl/) - REQUIRED
# ARM (aarch64)
GO_TGZ_URL_ARM64="https://github.com/noelrubio143/aaa/releases/download/assets/go1.27.2.linux-arm64.tar.gz"
GO_TGZ_SHA256_ARM64="94f3e30b8e374bc285e7dadc11e0865726b9bc6e85b841ccceaabc0214c6b7c8"   # sha256 of go1.27.2.linux-arm64.tar.gz - REQUIRED for ARM
GO_TMP=/tmp/go-toolchain

go_fail() {
    echo "[ ERROR ] $1"
    rm -rf "$GO_TMP" "$BUILD_DIR" /tmp/gocache /tmp/gopath
    exit 1
}

case "$(uname -m)" in
    x86_64)        GO_TGZ_URL="$GO_TGZ_URL_AMD64"; GO_TGZ_SHA256="$GO_TGZ_SHA256_AMD64" ;;
    aarch64|arm64) GO_TGZ_URL="$GO_TGZ_URL_ARM64"; GO_TGZ_SHA256="$GO_TGZ_SHA256_ARM64" ;;
    *) go_fail "Unsupported CPU: $(uname -m) (only x86_64 and aarch64)." ;;
esac
[ -n "$GO_TGZ_URL" ] || go_fail "Go tarball URL is empty for $(uname -m) - set it in this script."
[ -n "$GO_TGZ_SHA256" ] || go_fail "Go tarball sha256 is empty for $(uname -m) - set it in this script."

rm -rf "$GO_TMP"; mkdir -p "$GO_TMP"
wget -q -O "$GO_TMP/go.tgz" "$GO_TGZ_URL" || go_fail "Cannot download the Go tarball from GitHub."
echo "$GO_TGZ_SHA256  $GO_TMP/go.tgz" | sha256sum -c - >/dev/null 2>&1 || go_fail "Go tarball sha256 mismatch - refusing to use it."
tar -C "$GO_TMP" -xzf "$GO_TMP/go.tgz" || go_fail "Cannot extract the Go tarball."
GO_BIN="$GO_TMP/go/bin/go"
[ -x "$GO_BIN" ] || go_fail "go binary not found inside the tarball."

# go.mod build (works on every Go version; GOPATH mode is not needed)
export HOME=/root GOCACHE=/tmp/gocache GOPATH=/tmp/gopath GOTOOLCHAIN=local GOPROXY=off GO111MODULE=on CGO_ENABLED=0
if (cd "$BUILD_DIR" && "$GO_BIN" mod init wsgo >/dev/null 2>&1 \
    && "$GO_BIN" build -ldflags "-s -w" -o ws-go .); then
    GO_OK=1
fi
# the toolchain is only needed for the build
rm -rf "$GO_TMP" /tmp/gocache /tmp/gopath

if [ "$GO_OK" != "1" ]; then
    echo "[ ERROR ] Go build failed (see the error above)."
    exit 1
fi

echo "[ OK ] Go proxy built"
systemctl stop ws-dropbear ws-stunnel 2>/dev/null || true
install -m 755 "$BUILD_DIR/ws-go" /usr/local/bin/ws-dropbear
install -m 755 "$BUILD_DIR/ws-go" /usr/local/bin/ws-stunnel
DROP_EXEC="/usr/local/bin/ws-dropbear 2095"
STUN_EXEC="/usr/local/bin/ws-stunnel -b 127.0.0.1 -p 700"

rm -rf "$BUILD_DIR" /tmp/gocache /tmp/gopath

# ---- systemd services (non-TLS ws-dropbear :2095, ws-stunnel :700) ----
cat > /etc/systemd/system/ws-dropbear.service <<EOF
[Unit]
Description=Websocket-Dropbear
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$DROP_EXEC
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/ws-stunnel.service <<EOF
[Unit]
Description=SSH Over Websocket
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=on-failure
ExecStart=$STUN_EXEC

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

#Diagnostic script
wget -O /usr/local/bin/check-sshws.sh https://raw.githubusercontent.com/noelrubio143/aaa/main/sshws/check-sshws.sh
chmod +x /usr/local/bin/check-sshws.sh

# ========== PART 3: Start services ==========

echo "[5/6] Enabling and starting services..."
systemctl enable --now ws-dropbear >/dev/null 2>&1 || echo "[!] ws-dropbear failed to start - check: journalctl -u ws-dropbear -e"
systemctl enable --now ws-stunnel >/dev/null 2>&1  || echo "[!] ws-stunnel failed to start - check: journalctl -u ws-stunnel -e"

# ========== PART 4: Start All Services ==========

echo "[6/6] Starting services..."
systemctl daemon-reload


sleep 2

# ========== Verification ==========

echo ""
echo "========================================="
echo "✅ Installation Complete!"
echo "========================================="
echo ""
echo "Services:"
for svc in ws-dropbear ws-stunnel gomux; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
        if systemctl is-active --quiet "$svc"; then
            echo "  ✓ $svc: RUNNING"
        else
            echo "  ✗ $svc: FAILED"
        fi
    fi
done

echo ""
echo "Ports:"
ss -tlnp 2>/dev/null | grep -E ":(80|443|2095|700)" || echo "  (checking...)"


echo ""
echo "Full diagnostic:"
echo "  bash /usr/local/bin/check-sshws.sh"
echo ""
