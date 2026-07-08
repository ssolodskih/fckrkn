// yacfsocks local client (Go port of client.py) — a minimal SOCKS5 server that
// tunnels each TCP connection to a Yandex Cloud Function over HTTPS.
//
// YC spreads invocations across one instance per availability zone with no
// session stickiness, BUT a single HTTP keep-alive connection pins to one
// instance. So each SOCKS session gets its own *http.Client (its own pinned
// connection) and drives it serially with one "exchange" call per round —
// send-upstream + return-downstream — so all its calls reach the instance that
// holds its socket.
//
// Config via env: FUNCTION_URL, TOKEN, LISTEN (host:port, default
// 127.0.0.1:1080), SOCKS_USER, SOCKS_PASS, MAX_INFLIGHT (default 9),
// INSECURE=1, DEBUG=1.
//
// Single static binary, stdlib only. Build: see build.sh.
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// SOCKS5 constants (RFC 1928 / 1929).
const (
	socksVer    = 0x05
	mNoAuth     = 0x00
	mUserPass   = 0x02
	mNone       = 0xFF
	cmdConnect  = 0x01
	atypIPv4    = 0x01
	atypDomain  = 0x03
	atypIPv6    = 0x04
	upPoll      = 20 * time.Millisecond // wait for upstream bytes before each exchange
	callTimeout = 70 * time.Second      // per HTTP call (server long-polls ~0.5s)
)

var debug = os.Getenv("DEBUG") == "1"

type config struct {
	scheme string
	host   string // host[:port]
	path   string
	token  string
	listen string
	user   string
	pass   string
	hasCfg  bool // SOCKS auth required
	tlsCfg  *tls.Config
	sem     chan struct{} // caps concurrent function calls (YC zone quota is 10)
	dialCtx func(ctx context.Context, network, addr string) (net.Conn, error)
}

// Public resolvers used only if the phone's own DNS can't be discovered.
// (Yandex DNS included — most likely reachable on a Yandex-whitelisted network.)
var fallbackDNS = []string{"77.88.8.8", "1.1.1.1", "8.8.8.8"}

// dnsServers returns the DNS resolver addresses to use. Android has no
// /etc/resolv.conf, so Go's resolver falls back to localhost:53 (nothing there)
// and every lookup fails with "connection refused". Discover the real servers
// from YACF_DNS, then Android's system properties, then public fallbacks.
func dnsServers() []string {
	if s := splitClean(os.Getenv("YACF_DNS")); len(s) > 0 {
		return s
	}
	if s := scanGetpropDNS(); len(s) > 0 {
		return s
	}
	return fallbackDNS
}

func splitClean(v string) []string {
	var out []string
	for _, p := range strings.Split(v, ",") {
		if p = strings.TrimSpace(p); p != "" && net.ParseIP(p) != nil {
			out = append(out, p)
		}
	}
	return out
}

// scanGetpropDNS parses `getprop` output for every key containing "dns" and
// collects valid IP values (net.dns1 is gone on Android 8+, but the DHCP lease
// props like dhcp.wlan0.dns1 usually hold the active resolver).
func scanGetpropDNS() []string {
	out, err := exec.Command("/system/bin/getprop").Output()
	if err != nil {
		return nil
	}
	var res []string
	seen := map[string]bool{}
	for _, line := range strings.Split(string(out), "\n") {
		if !strings.Contains(strings.ToLower(line), "dns") {
			continue
		}
		i := strings.Index(line, "]: [")
		if i < 0 {
			continue
		}
		val := strings.TrimSpace(strings.TrimSuffix(line[i+4:], "]"))
		if val != "" && net.ParseIP(val) != nil && !seen[val] {
			seen[val] = true
			res = append(res, val)
		}
	}
	return res
}

// buildResolver returns a resolver that queries the given DNS servers directly,
// or nil to use Go's default (fine on a normal Linux desktop).
func buildResolver() *net.Resolver {
	servers := dnsServers()
	if len(servers) == 0 {
		return nil
	}
	if debug {
		log.Printf("dns servers: %v", servers)
	}
	return &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			var lastErr error
			for _, s := range servers {
				for _, proto := range []string{"udp", "tcp"} {
					c, err := d.DialContext(ctx, proto, net.JoinHostPort(s, "53"))
					if err == nil {
						return c, nil
					}
					lastErr = err
				}
			}
			return nil, lastErr
		},
	}
}

func newConfig() (*config, error) {
	raw := os.Getenv("FUNCTION_URL")
	if raw == "" {
		return nil, fmt.Errorf("FUNCTION_URL is required")
	}
	u, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("bad FUNCTION_URL: %w", err)
	}
	if u.Scheme == "" {
		u.Scheme = "https"
	}
	path := u.Path
	if path == "" {
		path = "/"
	}
	listen := os.Getenv("LISTEN")
	if listen == "" {
		listen = "127.0.0.1:1080"
	}
	maxInflight := 9
	if v := os.Getenv("MAX_INFLIGHT"); v != "" {
		if n, e := strconv.Atoi(v); e == nil && n > 0 {
			maxInflight = n
		}
	}
	user, userSet := os.LookupEnv("SOCKS_USER")
	cfg := &config{
		scheme: u.Scheme,
		host:   u.Host,
		path:   path,
		token:  os.Getenv("TOKEN"),
		listen: listen,
		user:   user,
		pass:   os.Getenv("SOCKS_PASS"),
		hasCfg: userSet,
		tlsCfg: &tls.Config{InsecureSkipVerify: os.Getenv("INSECURE") == "1"},
		sem:    make(chan struct{}, maxInflight),
	}
	// Resolve DNS via the system servers (Android has no resolv.conf).
	dialer := &net.Dialer{Timeout: 10 * time.Second, Resolver: buildResolver()}
	cfg.dialCtx = dialer.DialContext
	// Load a usable trust store unless verification is disabled.
	if !cfg.tlsCfg.InsecureSkipVerify {
		cfg.tlsCfg.RootCAs = rootCAs()
	}
	return cfg, nil
}

// rootCAs assembles a trust store that works on Android, where a static Go
// binary finds no system roots (x509: certificate signed by unknown authority).
// Pulls in Go's SystemCertPool (honors SSL_CERT_FILE), Termux's ca bundle, and
// Android's system/APEX CA directories.
func rootCAs() *x509.CertPool {
	pool, _ := x509.SystemCertPool()
	if pool == nil {
		pool = x509.NewCertPool()
	}
	for _, f := range []string{
		os.Getenv("SSL_CERT_FILE"),
		os.Getenv("PREFIX") + "/etc/tls/cert.pem",
		"/data/data/com.termux/files/usr/etc/tls/cert.pem",
	} {
		if f == "" {
			continue
		}
		if b, err := os.ReadFile(f); err == nil {
			pool.AppendCertsFromPEM(b)
		}
	}
	// Android trust store: one PEM per file in these dirs.
	for _, d := range []string{
		"/system/etc/security/cacerts",
		"/apex/com.android.conscrypt/cacerts",
	} {
		entries, err := os.ReadDir(d)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if b, err := os.ReadFile(filepath.Join(d, e.Name())); err == nil {
				pool.AppendCertsFromPEM(b)
			}
		}
	}
	return pool
}

// newSessionClient returns an *http.Client with its OWN transport, so its TCP
// connection is isolated from other sessions and reused across this session's
// serial calls — i.e. pinned to one warm instance. HTTP/1.1 only (one request
// in flight at a time per connection matches the serial exchange loop).
func (c *config) newSessionClient() *http.Client {
	tr := &http.Transport{
		MaxIdleConns:        1,
		MaxIdleConnsPerHost: 1,
		MaxConnsPerHost:     1,
		IdleConnTimeout:     90 * time.Second,
		TLSClientConfig:     c.tlsCfg,
		ForceAttemptHTTP2:   false,
		TLSNextProto:        map[string]func(string, *tls.Conn) http.RoundTripper{}, // disable h2
		DialContext:         c.dialCtx,
	}
	return &http.Client{Transport: tr, Timeout: callTimeout}
}

// rpc runs one request/response over the session's pinned client, injecting the
// token and retrying on HTTP 429 (YC concurrency quota) with backoff.
func (c *config) rpc(client *http.Client, obj map[string]any) map[string]any {
	obj["token"] = c.token
	body, _ := json.Marshal(obj)
	full := c.scheme + "://" + c.host + c.path
	delay := 200 * time.Millisecond
	for i := 0; i < 6; i++ {
		c.sem <- struct{}{}
		out, status, err := doPost(client, full, body)
		<-c.sem
		if err != nil {
			return map[string]any{"error": "call_failed", "detail": err.Error()}
		}
		if status == 429 {
			time.Sleep(delay)
			if delay < 2*time.Second {
				delay *= 2
			}
			continue
		}
		if status != 200 {
			return map[string]any{"error": "http", "detail": strconv.Itoa(status)}
		}
		var r map[string]any
		if e := json.Unmarshal(out, &r); e != nil {
			return map[string]any{"error": "bad_response", "detail": e.Error()}
		}
		return r
	}
	return map[string]any{"error": "rate_limited"}
}

func doPost(client *http.Client, full string, body []byte) ([]byte, int, error) {
	req, err := http.NewRequest("POST", full, bytes.NewReader(body))
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	out, err := io.ReadAll(resp.Body) // must fully read to reuse the keep-alive connection
	if err != nil {
		return nil, resp.StatusCode, err
	}
	return out, resp.StatusCode, nil
}

// --- SOCKS5 ---

func reply(rep byte) []byte {
	return []byte{socksVer, rep, 0x00, atypIPv4, 0, 0, 0, 0, 0, 0}
}

func readFull(conn net.Conn, n int) ([]byte, error) {
	buf := make([]byte, n)
	_, err := io.ReadFull(conn, buf)
	return buf, err
}

// negotiate runs the SOCKS5 greeting + optional user/pass auth.
func negotiate(conn net.Conn, c *config) bool {
	hdr, err := readFull(conn, 2)
	if err != nil || hdr[0] != socksVer {
		return false
	}
	methods, err := readFull(conn, int(hdr[1]))
	if err != nil {
		return false
	}
	has := func(m byte) bool { return bytes.IndexByte(methods, m) >= 0 }
	var method byte = mNone
	if c.hasCfg && has(mUserPass) {
		method = mUserPass
	} else if !c.hasCfg && has(mNoAuth) {
		method = mNoAuth
	}
	if _, err := conn.Write([]byte{socksVer, method}); err != nil {
		return false
	}
	if method == mNone {
		return false
	}
	if method == mUserPass {
		v, err := readFull(conn, 1)
		if err != nil || v[0] != 0x01 {
			return false
		}
		ul, err := readFull(conn, 1)
		if err != nil {
			return false
		}
		uname, err := readFull(conn, int(ul[0]))
		if err != nil {
			return false
		}
		pl, err := readFull(conn, 1)
		if err != nil {
			return false
		}
		passwd, err := readFull(conn, int(pl[0]))
		if err != nil {
			return false
		}
		ok := string(uname) == c.user && string(passwd) == c.pass
		var status byte = 0x01
		if ok {
			status = 0x00
		}
		conn.Write([]byte{0x01, status})
		return ok
	}
	return true
}

// readRequest parses a SOCKS5 CONNECT request, returning "host:port".
func readRequest(conn net.Conn) (string, bool) {
	hdr, err := readFull(conn, 4) // ver, cmd, rsv, atyp
	if err != nil || hdr[0] != socksVer || hdr[1] != cmdConnect {
		return "", false
	}
	var host string
	switch hdr[3] {
	case atypIPv4:
		b, e := readFull(conn, 4)
		if e != nil {
			return "", false
		}
		host = net.IP(b).String()
	case atypIPv6:
		b, e := readFull(conn, 16)
		if e != nil {
			return "", false
		}
		host = net.IP(b).String()
	case atypDomain:
		l, e := readFull(conn, 1)
		if e != nil {
			return "", false
		}
		b, e := readFull(conn, int(l[0]))
		if e != nil {
			return "", false
		}
		host = string(b)
	default:
		return "", false
	}
	pb, err := readFull(conn, 2)
	if err != nil {
		return "", false
	}
	port := binary.BigEndian.Uint16(pb)
	return net.JoinHostPort(host, strconv.Itoa(int(port))), true
}

// bridge runs the serial exchange loop over the pinned client.
func bridge(conn net.Conn, c *config, client *http.Client, sid string) {
	buf := make([]byte, 65536)
	for {
		conn.SetReadDeadline(time.Now().Add(upPoll))
		n, err := conn.Read(buf)
		var up []byte
		if n > 0 {
			up = append([]byte(nil), buf[:n]...)
		}
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				// no upstream bytes this tick; still poll downstream
			} else {
				return // EOF or local error
			}
		}
		obj := map[string]any{"action": "exchange", "sid": sid}
		if len(up) > 0 {
			obj["data"] = base64.StdEncoding.EncodeToString(up)
		}
		r := c.rpc(client, obj)
		errStr, _ := r["error"].(string)
		closed, _ := r["closed"].(bool)
		dataStr, _ := r["data"].(string)
		if debug && (len(up) > 0 || dataStr != "" || errStr != "" || closed) {
			short := sid
			if len(short) > 6 {
				short = short[:6]
			}
			dn := 0
			if dataStr != "" {
				if dec, e := base64.StdEncoding.DecodeString(dataStr); e == nil {
					dn = len(dec)
				}
			}
			log.Printf("ex %s up=%d down=%d err=%s closed=%v", short, len(up), dn, errStr, closed)
		}
		if errStr != "" || closed {
			return
		}
		if dataStr != "" {
			dec, e := base64.StdEncoding.DecodeString(dataStr)
			if e != nil {
				return
			}
			conn.SetWriteDeadline(time.Now().Add(30 * time.Second))
			if _, e := conn.Write(dec); e != nil {
				return
			}
		}
	}
}

func handle(conn net.Conn, c *config) {
	var sid string
	var client *http.Client
	defer func() {
		if sid != "" && client != nil {
			c.rpc(client, map[string]any{"action": "close", "sid": sid})
		}
		if client != nil {
			client.CloseIdleConnections()
		}
		conn.Close()
	}()

	if !negotiate(conn, c) {
		return
	}
	dst, ok := readRequest(conn)
	if !ok {
		conn.Write(reply(0x07)) // command not supported
		return
	}
	client = c.newSessionClient() // pinned keep-alive connection for this session
	r := c.rpc(client, map[string]any{"action": "open", "dst": dst})
	s, _ := r["sid"].(string)
	if s == "" {
		log.Printf("open %s FAILED: %v", dst, r)
		conn.Write(reply(0x05)) // connection refused
		return
	}
	sid = s
	log.Printf("open %s -> %s (port %v)", dst, shortID(sid), r["port"])
	if _, err := conn.Write(reply(0x00)); err != nil {
		return
	}
	bridge(conn, c, client, sid)
}

func shortID(s string) string {
	if len(s) > 6 {
		return s[:6]
	}
	return s
}

func main() {
	log.SetFlags(0)
	cfg, err := newConfig()
	if err != nil {
		fmt.Fprintln(os.Stderr, "yacfsocks:", err)
		os.Exit(2)
	}
	ln, err := net.Listen("tcp", cfg.listen)
	if err != nil {
		fmt.Fprintln(os.Stderr, "yacfsocks: listen:", err)
		os.Exit(1)
	}
	auth := "no-auth"
	if cfg.hasCfg {
		auth = "user/pass"
	}
	endpoint := cfg.scheme + "://" + cfg.host + cfg.path
	log.Printf("yacfsocks SOCKS5 on %s (%s) -> %s", cfg.listen, auth, endpoint)
	for {
		conn, err := ln.Accept()
		if err != nil {
			if strings.Contains(err.Error(), "use of closed") {
				return
			}
			continue
		}
		go handle(conn, cfg)
	}
}
