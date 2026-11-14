#!/bin/bash
###############################################################################
# gomux edge installer for aaa-main
#
#   :80   raw SSH -> 22 | raw OpenVPN -> 1194 | HTTP payload -> router
#   :443  raw SSH -> 22 | raw OpenVPN -> 1194 | plain HTTP -> router | TLS(h2) -> xray paths
#         TLS(any SNI) -> SSH -> 22, raw OpenVPN -> 1194, else router
#   router: /vless /vmess /trojan-ws /xhttp-* -> xray,
#           /dropbear-ws -> 2095,
#           everything else -> ws-stunnel (700)
#
# The Go source is embedded below and built on the VPS. The build happens
# BEFORE anything is stopped, so a failed build leaves the old edge untouched.
###############################################################################

set -e

red='\033[0;31m'; green='\033[0;32m'; blue='\033[0;34m'; NC='\033[0m'

echo -e "${blue}[*] Installing gomux edge layer${NC}"

if [ ! -f /etc/xray/xray.crt ] || [ ! -f /etc/xray/xray.key ]; then
    echo -e "${red}[-] Error: /etc/xray/xray.crt or xray.key not found${NC}"
    exit 1
fi

# ---- Go source embedded in this script (xray/gomux.go), built locally on the VPS ----
BUILD_DIR=/tmp/gomux-build
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
cat > "$BUILD_DIR/gomux.go" <<'GOEOF'
// gomux - Go edge multiplexer for aaa-main (ports 80 and 443).
//
//   :80   raw SSH            -> 22
//         raw OpenVPN (tcp)  -> 1194
//         HTTP payload       -> router (below)
//   :443  raw SSH            -> 22
//         raw OpenVPN (tcp)  -> 1194
//         plain HTTP         -> router
//         TLS (h2 offered)   -> TLS terminate -> HTTP path routing to xray
//         TLS (any SNI)      -> TLS terminate -> SSH- -> 22, else router
//
//   router:
//         " /vless" " /vmess" " /trojan-ws" " /xhttp-"  -> xray (by exact path)
//         " /dropbear-ws"                                -> ws-dropbear (2095)
//         everything else                                -> ws-stunnel  (700)
//
// Build:  go mod init gomux && go build -ldflags "-s -w" -o gomux .
// Test on other ports:  ./gomux -http :9080 -tls :9443
// Normal run uses the defaults (:80 / :443).

package main

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"errors"
	"flag"
	"io"
	"io/ioutil"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"sync"
	"strings"
	"time"
)

var (
	sshAddr     = "127.0.0.1:22"
	ovpnAddr    = "127.0.0.1:1194"
	stunnelAddr = "127.0.0.1:700"
	dbwsAddr    = "127.0.0.1:2095"

	vlessAddr  = "127.0.0.1:14016"
	vmessAddr  = "127.0.0.1:23456"
	trojanAddr = "127.0.0.1:25432"
	xhVlAddr   = "127.0.0.1:14017"
	xhVmAddr   = "127.0.0.1:23457"
	xhTrAddr   = "127.0.0.1:25433"

	plainL *chanListener // cleartext HTTP (xray paths)  -> http.Server
	tlsL   *chanListener // TLS + h2                     -> http.Server
	tlsCfg *tls.Config

)

// ---------------------------------------------------------------- helpers

type chanListener struct{ ch chan net.Conn }

func (l *chanListener) Accept() (net.Conn, error) {
	c, ok := <-l.ch
	if !ok {
		return nil, errors.New("listener closed")
	}
	return c, nil
}
func (l *chanListener) Close() error   { return nil }
func (l *chanListener) Addr() net.Addr { return &net.TCPAddr{} }

// bconn: a connection whose first bytes can be peeked without being lost.
type bconn struct {
	net.Conn
	r *bufio.Reader
}

func newB(c net.Conn) *bconn { return &bconn{Conn: c, r: bufio.NewReaderSize(c, 16384)} }

func (b *bconn) Read(p []byte) (int, error) { return b.r.Read(p) }

func isTimeout(err error) bool {
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}

type kind int

const (
	kUnknown kind = iota // nothing arrived within 2s
	kTLS
	kSSH
	kOVPN // raw OpenVPN-over-TCP handshake (no HTTP payload)
	kHTTP // anything else (first line / first packet in data)
)

// classify peeks at the first bytes (waits up to 2s for the client).
func classify(b *bconn, allowTLS bool) (kind, []byte, error) {
	b.SetReadDeadline(time.Now().Add(2 * time.Second))
	defer b.SetReadDeadline(time.Time{})

	first, err := b.r.Peek(1)
	if err != nil {
		if isTimeout(err) {
			return kUnknown, nil, nil
		}
		return kUnknown, nil, err
	}
	if allowTLS && first[0] == 0x16 {
		return kTLS, nil, nil
	}
	head, _ := b.r.Peek(7)
	if string(head) == "SSH-2.0" {
		return kSSH, nil, nil
	}
	// OpenVPN over TCP starts with a 2-byte length (< 256 -> first byte 0x00) followed by the
	// opcode byte of P_CONTROL_HARD_RESET_CLIENT_V2 (0x38) / _V1 (0x30). Text protocols
	// (HTTP) never start with a NUL byte.
	if len(head) >= 3 && head[0] == 0x00 && (head[2] == 0x38 || head[2] == 0x30) {
		return kOVPN, nil, nil
	}
	// wait for the end of the first line (or timeout / 8 KB)
	for {
		n := b.r.Buffered()
		data, _ := b.r.Peek(n)
		if bytes.IndexByte(data, '\n') >= 0 || n >= 8192 {
			return kHTTP, data, nil
		}
		if _, err := b.r.Peek(n + 1); err != nil {
			return kHTTP, data, nil
		}
	}
}

// ---------------------------------------------------------------- certificate
// gomux is the only component that touches the certificate:
//  - it hot-reloads the certificate files (self-signed on the VPS IP), so a new
//    cert from m-ssl needs no restart

type certStore struct {
	mu        sync.Mutex
	crt, key  string
	cert      *tls.Certificate
	mtime     time.Time
	lastCheck time.Time
}

func (s *certStore) load() error {
	st, err := os.Stat(s.crt)
	if err != nil {
		return err
	}
	c, err := tls.LoadX509KeyPair(s.crt, s.key)
	if err != nil {
		return err
	}
	s.cert, s.mtime = &c, st.ModTime()
	return nil
}

// get is used as tls.Config.GetCertificate; it re-checks the file at most every 30s.
func (s *certStore) get(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if time.Since(s.lastCheck) > 30*time.Second {
		s.lastCheck = time.Now()
		if st, err := os.Stat(s.crt); err == nil && !st.ModTime().Equal(s.mtime) {
			if err := s.load(); err != nil {
				log.Println("cert reload:", err) // keep serving the old one
			} else {
				log.Println("cert reloaded")
			}
		}
	}
	return s.cert, nil
}

func relay(c net.Conn, addr string) {
	d, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		log.Println("dial", addr, err)
		c.Close()
		return
	}
	done := make(chan struct{}, 2)
	go func() { io.Copy(d, c); done <- struct{}{} }()
	go func() { io.Copy(c, d); done <- struct{}{} }()
	<-done
	c.Close()
	d.Close()
}

func hasXrayPath(data []byte) bool {
	l := bytes.ToLower(data)
	for _, p := range []string{" /vless", " /vmess", " /trojan-ws", " /xhttp-"} {
		if bytes.Contains(l, []byte(p)) {
			return true
		}
	}
	return false
}

// router decides where an HTTP payload goes (xray paths, ws-dropbear, ws-stunnel).
func router(c net.Conn, k kind, data []byte) {
	switch {
	case k == kSSH:
		relay(c, sshAddr)
	case k == kOVPN:
		relay(c, ovpnAddr)
	case k == kHTTP && hasXrayPath(data):
		plainL.ch <- c
	case k == kHTTP && bytes.Contains(bytes.ToLower(data), []byte(" /dropbear-ws")):
		relay(c, dbwsAddr)
	default:
		relay(c, stunnelAddr)
	}
}

// ---------------------------------------------------------------- entry points

func handle80(c net.Conn) {
	b := newB(c)
	k, data, err := classify(b, false)
	if err != nil {
		c.Close()
		return
	}
	router(b, k, data)
}

func handle443(c net.Conn) {
	b := newB(c)
	k, data, err := classify(b, true)
	if err != nil {
		c.Close()
		return
	}
	switch k {
	case kSSH:
		relay(b, sshAddr)
	case kOVPN:
		relay(b, ovpnAddr)
	case kHTTP:
		router(b, k, data)
	case kTLS:
		handleTLS(b)
	default:
		c.Close()
	}
}

// handleTLS terminates TLS: h2 clients go to the xray HTTP tier, others are classified again.
func handleTLS(b *bconn) {
	tc := tls.Server(b, tlsCfg)
	tc.SetDeadline(time.Now().Add(10 * time.Second))
	if err := tc.Handshake(); err != nil {
		tc.Close()
		return
	}
	tc.SetDeadline(time.Time{})

	if tc.ConnectionState().NegotiatedProtocol == "h2" {
		tlsL.ch <- tc // http.Server speaks h2 and routes by path
		return
	}
	nb := newB(tc)
	k, data, err := classify(nb, false)
	if err != nil {
		tc.Close()
		return
	}
	router(nb, k, data)
}

// ---------------------------------------------------------------- xray http tier

func newXrayHandler() http.Handler {
	mk := func(addr string) *httputil.ReverseProxy {
		p := httputil.NewSingleHostReverseProxy(&url.URL{Scheme: "http", Host: addr})
		p.FlushInterval = -1
		p.Transport = &http.Transport{
			DialContext:        (&net.Dialer{Timeout: 5 * time.Second}).DialContext,
			DisableCompression: true,
			MaxIdleConnsPerHost: 64,
			IdleConnTimeout:    90 * time.Second,
		}
		orig := p.Director
		p.Director = func(r *http.Request) {
			orig(r)
			if h, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
				r.Header.Set("X-Real-IP", h)
			}
		}
		p.ErrorLog = log.New(ioutil.Discard, "", 0)
		return p
	}
	vless, vmess, trojan := mk(vlessAddr), mk(vmessAddr), mk(trojanAddr)
	xhVl, xhVm, xhTr := mk(xhVlAddr), mk(xhVmAddr), mk(xhTrAddr)

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		switch lp := strings.ToLower(p); {
		case lp == "/vless":
			vless.ServeHTTP(w, r)
		case lp == "/vmess":
			vmess.ServeHTTP(w, r)
		case lp == "/trojan-ws":
			trojan.ServeHTTP(w, r)
		case strings.HasPrefix(p, "/xhttp-vless"):
			xhVl.ServeHTTP(w, r)
		case strings.HasPrefix(p, "/xhttp-vmess"):
			xhVm.ServeHTTP(w, r)
		case strings.HasPrefix(p, "/xhttp-trojan"):
			xhTr.ServeHTTP(w, r)
		default:
			http.Error(w, "503 Service Unavailable", http.StatusServiceUnavailable)
		}
	})
}

func listen(addr string, h func(net.Conn)) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal(err)
	}
	log.Println("listening on", addr)
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Println(err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go h(c)
	}
}

func main() {
	httpAddr := flag.String("http", ":80", "cleartext listen address")
	tlsAddr := flag.String("tls", ":443", "TLS listen address")
	certFile := flag.String("cert", "/etc/xray/xray.crt", "TLS certificate")
	keyFile := flag.String("key", "/etc/xray/xray.key", "TLS private key")
	flag.StringVar(&sshAddr, "ssh", sshAddr, "OpenSSH target")
	flag.StringVar(&ovpnAddr, "ovpn", ovpnAddr, "OpenVPN target (raw OpenVPN handshake)")
	flag.StringVar(&stunnelAddr, "stunnel", stunnelAddr, "ws-stunnel target (default route)")
	flag.StringVar(&dbwsAddr, "dbws", dbwsAddr, "ws-dropbear target (/dropbear-ws)")
	flag.Parse()

	store := &certStore{crt: *certFile, key: *keyFile}
	if err := store.load(); err != nil {
		log.Fatal("cert: ", err)
	}
	store.lastCheck = time.Now()
	cfgH2 := &tls.Config{
		GetCertificate: store.get,
		MinVersion:   tls.VersionTLS10,
		NextProtos:   []string{"h2", "http/1.1"},
	}
	tlsCfg = &tls.Config{
		GetCertificate: store.get,
		MinVersion:   tls.VersionTLS10,
		// clients that offer h2 get the h2-capable config,
		// everyone else gets no ALPN
		GetConfigForClient: func(h *tls.ClientHelloInfo) (*tls.Config, error) {
			for _, p := range h.SupportedProtos {
				if p == "h2" {
					return cfgH2, nil
				}
			}
			return nil, nil
		},
	}

	plainL = &chanListener{ch: make(chan net.Conn, 64)}
	tlsL = &chanListener{ch: make(chan net.Conn, 64)}
	handler := newXrayHandler()
	quiet := log.New(ioutil.Discard, "", 0)
	go (&http.Server{Handler: handler, IdleTimeout: 24 * time.Hour, ErrorLog: quiet}).Serve(plainL)
	go (&http.Server{Handler: handler, IdleTimeout: 24 * time.Hour, ErrorLog: quiet}).Serve(tlsL)

	go listen(*httpAddr, handle80)
	listen(*tlsAddr, handle443)
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
    echo -e "${red}[x] $1 Nothing was changed.${NC}"
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
    && "$GO_BIN" build -ldflags "-s -w" -o gomux .); then
    GO_OK=1
fi
# the toolchain is only needed for the build
rm -rf "$GO_TMP" /tmp/gocache /tmp/gopath

if [ "$GO_OK" != "1" ]; then
    echo -e "${red}[-] gomux build failed. Old edge layer (if any) was NOT touched.${NC}"
    rm -rf "$BUILD_DIR" /tmp/gocache /tmp/gopath
    exit 1
fi
echo -e "${green}[+] gomux built${NC}"

systemctl stop gomux 2>/dev/null || true

install -m 755 "$BUILD_DIR/gomux" /usr/local/bin/gomux
rm -rf "$BUILD_DIR" /tmp/gocache /tmp/gopath

cat > /etc/systemd/system/gomux.service <<'EOF'
[Unit]
Description=gomux edge layer (80/443 multiplexer)
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/gomux
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=1048576
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now gomux >/dev/null 2>&1 || true
sleep 1

if systemctl is-active --quiet gomux; then
    echo -e "${green}[+] gomux is running${NC}"
else
    echo -e "${red}[-] gomux failed to start - check: journalctl -u gomux -e${NC}"
    systemctl status gomux --no-pager || true
    exit 1
fi

echo -e "${blue}[*] Architecture Summary:${NC}"
echo -e "    Port 80/443 (gomux)"
echo -e "      ├─ SSH detection  -> OpenSSH (22)"
echo -e "      ├─ raw OpenVPN    -> openvpn (1194)"
echo -e "      ├─ /vless /vmess /trojan-ws /xhttp-*  -> xray"
echo -e "      ├─ /dropbear-ws   -> ws-dropbear (2095)"
echo -e "      └─ everything else -> ws-stunnel (700)"
