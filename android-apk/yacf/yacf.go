// Package yacf is the yacfsocks relay core, packaged for gomobile bind.
//
// It runs a local SOCKS5 server that tunnels each TCP connection to a Yandex
// Cloud Function over HTTPS. YC spreads invocations across one instance per
// availability zone with no session stickiness, BUT a single HTTP keep-alive
// connection pins to one instance. So each SOCKS session gets its own
// *http.Client (its own pinned connection) and drives it serially with one
// "exchange" call per round — send-upstream + return-downstream — so all its
// calls reach the instance that holds its socket.
//
// This is a self-contained copy of the relay core from client-go/main.go,
// adapted for in-process use inside an Android app. The two on-device hacks the
// Termux binary needs are dropped here because a normal Android app doesn't need
// them: DNS goes through the cgo Bionic resolver (getaddrinfo), and TLS trust
// comes from x509.SystemCertPool, which knows Android's cacert dirs on
// GOOS=android. The wire protocol is unchanged.
//
// gomobile-exported surface: Start, Stop, Running, and the Logger interface.
package yacf

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"sync"
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
	maxInflight = 9                     // caps concurrent function calls (YC zone quota is 10)
)

// Logger lets the host app (Kotlin) receive log lines. gomobile maps this to a
// Java interface, so ProxyService can implement Log(String) and surface
// "open ... -> sid" lines in its notification. A nil Logger is fine.
type Logger interface {
	Log(msg string)
}

type config struct {
	scheme  string
	host    string // host[:port]
	path    string
	token   string
	listen  string
	tlsCfg  *tls.Config
	sem     chan struct{} // caps concurrent function calls
	dialCtx func(ctx context.Context, network, addr string) (net.Conn, error)
	log     Logger
	debug   bool
}

func (c *config) logf(format string, args ...any) {
	if c.log == nil {
		return
	}
	c.log.Log(fmt.Sprintf(format, args...))
}

func newConfig(functionURL, token, listen string, logger Logger) (*config, error) {
	if functionURL == "" {
		return nil, fmt.Errorf("function URL is required")
	}
	u, err := url.Parse(functionURL)
	if err != nil {
		return nil, fmt.Errorf("bad function URL: %w", err)
	}
	if u.Scheme == "" {
		u.Scheme = "https"
	}
	path := u.Path
	if path == "" {
		path = "/"
	}
	if listen == "" {
		listen = "127.0.0.1:1080"
	}
	// On GOOS=android the default dialer resolves via the cgo Bionic resolver
	// (getaddrinfo) and x509.SystemCertPool already trusts Android's CA dirs,
	// so no manual DNS/CA plumbing is needed here.
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	cfg := &config{
		scheme:  u.Scheme,
		host:    u.Host,
		path:    path,
		token:   token,
		listen:  listen,
		tlsCfg:  &tls.Config{},
		sem:     make(chan struct{}, maxInflight),
		dialCtx: dialer.DialContext,
		log:     logger,
	}
	return cfg, nil
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

// negotiate runs the SOCKS5 greeting. The app listens on loopback only, so it
// offers no-auth; there is no SOCKS user/pass.
func negotiate(conn net.Conn) bool {
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
	if has(mNoAuth) {
		method = mNoAuth
	}
	if _, err := conn.Write([]byte{socksVer, method}); err != nil {
		return false
	}
	return method != mNone
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
		if c.debug && (len(up) > 0 || dataStr != "" || errStr != "" || closed) {
			dn := 0
			if dataStr != "" {
				if dec, e := base64.StdEncoding.DecodeString(dataStr); e == nil {
					dn = len(dec)
				}
			}
			c.logf("ex %s up=%d down=%d err=%s closed=%v", shortID(sid), len(up), dn, errStr, closed)
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

	if !negotiate(conn) {
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
		c.logf("open %s FAILED: %v", dst, r)
		conn.Write(reply(0x05)) // connection refused
		return
	}
	sid = s
	c.logf("open %s -> %s (port %v)", dst, shortID(sid), r["port"])
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

// --- gomobile-exported control surface ---

var (
	mu  sync.Mutex
	ln  net.Listener
	cur *config
)

// Start builds the config, binds the listener, and spawns the accept loop in a
// goroutine. It returns once the socket is listening (or with an error). Passing
// an empty listen uses 127.0.0.1:1080. logger may be nil.
func Start(functionURL, token, listen string, logger Logger) error {
	mu.Lock()
	defer mu.Unlock()
	if ln != nil {
		return fmt.Errorf("already running")
	}
	cfg, err := newConfig(functionURL, token, listen, logger)
	if err != nil {
		return err
	}
	l, err := net.Listen("tcp", cfg.listen)
	if err != nil {
		return fmt.Errorf("listen %s: %w", cfg.listen, err)
	}
	ln = l
	cur = cfg
	endpoint := cfg.scheme + "://" + cfg.host + cfg.path
	cfg.logf("yacfsocks SOCKS5 on %s -> %s", cfg.listen, endpoint)
	go acceptLoop(l, cfg)
	return nil
}

func acceptLoop(l net.Listener, cfg *config) {
	for {
		conn, err := l.Accept()
		if err != nil {
			return // listener closed
		}
		go handle(conn, cfg)
	}
}

// Stop closes the listener. In-flight sessions unwind on their own.
func Stop() {
	mu.Lock()
	defer mu.Unlock()
	if ln != nil {
		ln.Close()
		ln = nil
		cur = nil
	}
}

// Running reports whether the listener is bound.
func Running() bool {
	mu.Lock()
	defer mu.Unlock()
	return ln != nil
}

// SetDebug toggles the verbose "ex ..." per-exchange log lines on the running
// instance (the "open ..." lines are always emitted).
func SetDebug(on bool) {
	mu.Lock()
	defer mu.Unlock()
	if cur != nil {
		cur.debug = on
	}
}
