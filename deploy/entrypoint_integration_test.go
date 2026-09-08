package main

import (
	"bytes"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestGatewayUIRequiresBasicAuth(t *testing.T) {
	bin := os.Getenv("AGW_BIN")
	if bin == "" {
		t.Skip("set AGW_BIN to the v1.5.0 agentgateway binary")
	}

	dir := t.TempDir()
	p := testPaths(dir)
	if err := prepare(p, mapGetenv(map[string]string{
		"UI_USER":     "admin",
		"UI_PASSWORD": "change-me",
	})); err != nil {
		t.Fatal(err)
	}

	cfg, err := os.ReadFile(p.configFile)
	if err != nil {
		t.Fatal(err)
	}
	cfg = bytes.ReplaceAll(cfg, []byte("/config/.htpasswd"), []byte(p.htpasswd))
	cfg = bytes.ReplaceAll(cfg, []byte("sqlite:///config/data.db"), []byte("sqlite:///"+filepath.ToSlash(filepath.Join(dir, "data.db"))))
	if err := os.WriteFile(p.configFile, cfg, 0o644); err != nil {
		t.Fatal(err)
	}

	port := freePort(t)
	cfg = bytes.ReplaceAll(cfg, []byte("port: 4000"), []byte(fmt.Sprintf("port: %d", port)))
	if err := os.WriteFile(p.configFile, cfg, 0o644); err != nil {
		t.Fatal(err)
	}

	cmd := exec.Command(bin, "-f", p.configFile)
	cmd.Dir = dir
	stderr := &bytes.Buffer{}
	cmd.Stdout = stderr
	cmd.Stderr = stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	})

	base := fmt.Sprintf("http://127.0.0.1:%d", port)
	waitHTTP(t, base+"/ui/", 20*time.Second)

	unauth, err := http.Get(base + "/ui/")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, unauth.Body)
	unauth.Body.Close()
	if unauth.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthenticated /ui/ = %d, want 401\nlogs:\n%s", unauth.StatusCode, stderr)
	}

	req, err := http.NewRequest(http.MethodGet, base+"/ui/", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.SetBasicAuth("admin", "change-me")
	auth, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(auth.Body)
	auth.Body.Close()
	if auth.StatusCode != http.StatusOK {
		t.Fatalf("authenticated /ui/ = %d, want 200\nbody: %s\nlogs:\n%s", auth.StatusCode, body, stderr)
	}

	// LLM/API routes on the same port are not covered by ui.policies.
	// Strict virtual keys return 401 "no API Key found" — not WWW-Authenticate: Basic.
	llm, err := http.Post(base+"/v1/chat/completions", "application/json", strings.NewReader(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	llmBody, _ := io.ReadAll(llm.Body)
	llm.Body.Close()
	if strings.Contains(strings.ToLower(llm.Header.Get("Www-Authenticate")), "basic") {
		t.Fatalf("LLM route should not require UI basic auth\nheaders: %v\nbody: %s\nlogs:\n%s", llm.Header, llmBody, stderr)
	}
	if strings.Contains(strings.ToLower(string(llmBody)), "basic authentication") {
		t.Fatalf("LLM route should not require UI basic auth\nbody: %s\nlogs:\n%s", llmBody, stderr)
	}
}

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := l.Addr().(*net.TCPAddr).Port
	_ = l.Close()
	return port
}

func waitHTTP(t *testing.T, url string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	var last error
	for time.Now().Before(deadline) {
		resp, err := http.Get(url)
		if err == nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
			return
		}
		last = err
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("gateway did not become reachable: %v", last)
}
