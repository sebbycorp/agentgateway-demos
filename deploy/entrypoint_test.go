package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSha1HtpasswdLineMatchesApacheVector(t *testing.T) {
	// htpasswd -nbs user password  →  user:{SHA}W6ph5Mm5Pz8GgiULbPgzG37mj9g=
	got := sha1HtpasswdLine("user", "password")
	want := "user:{SHA}W6ph5Mm5Pz8GgiULbPgzG37mj9g="
	if got != want {
		t.Fatalf("sha1HtpasswdLine = %q, want %q", got, want)
	}
}

func TestCredentialsRequirePassword(t *testing.T) {
	_, _, err := credentialsFromEnv(func(k string) string {
		if k == "UI_USER" {
			return "admin"
		}
		return ""
	})
	if err == nil {
		t.Fatal("expected error when UI_PASSWORD is missing")
	}
	if !strings.Contains(err.Error(), "UI_PASSWORD") {
		t.Fatalf("error %q should mention UI_PASSWORD", err)
	}
}

func TestCredentialsDefaultUser(t *testing.T) {
	user, pass, err := credentialsFromEnv(func(k string) string {
		if k == "UI_PASSWORD" {
			return "s3cret"
		}
		return ""
	})
	if err != nil {
		t.Fatal(err)
	}
	if user != "admin" || pass != "s3cret" {
		t.Fatalf("got %q/%q, want admin/s3cret", user, pass)
	}
}

func TestCredentialsCustomUser(t *testing.T) {
	user, _, err := credentialsFromEnv(func(k string) string {
		switch k {
		case "UI_USER":
			return "ops"
		case "UI_PASSWORD":
			return "s3cret"
		}
		return ""
	})
	if err != nil {
		t.Fatal(err)
	}
	if user != "ops" {
		t.Fatalf("user = %q, want ops", user)
	}
}

func TestPrepareWritesHtpasswdAndSeed(t *testing.T) {
	dir := t.TempDir()
	p := testPaths(dir)
	env := map[string]string{"UI_PASSWORD": "s3cret"}
	if err := prepare(p, mapGetenv(env)); err != nil {
		t.Fatal(err)
	}

	ht, err := os.ReadFile(p.htpasswd)
	if err != nil {
		t.Fatal(err)
	}
	wantLine := sha1HtpasswdLine("admin", "s3cret") + "\n"
	if string(ht) != wantLine {
		t.Fatalf("htpasswd = %q, want %q", ht, wantLine)
	}

	cfg, err := os.ReadFile(p.configFile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(cfg), "ui.policies.basicAuth") && !hasUIBasicAuth(cfg) {
		t.Fatalf("seed config missing basicAuth:\n%s", cfg)
	}
	if !strings.Contains(string(cfg), "file: /config/.htpasswd") {
		t.Fatalf("seed config should use file-based htpasswd:\n%s", cfg)
	}
	if !strings.Contains(string(cfg), "mode: strict") {
		t.Fatalf("seed config should set mode strict:\n%s", cfg)
	}
}

func TestPrepareRewritesHtpasswdEachStart(t *testing.T) {
	dir := t.TempDir()
	p := testPaths(dir)
	if err := prepare(p, mapGetenv(map[string]string{"UI_PASSWORD": "first"})); err != nil {
		t.Fatal(err)
	}
	if err := prepare(p, mapGetenv(map[string]string{
		"UI_USER":     "ops",
		"UI_PASSWORD": "second",
	})); err != nil {
		t.Fatal(err)
	}
	ht, err := os.ReadFile(p.htpasswd)
	if err != nil {
		t.Fatal(err)
	}
	if string(ht) != sha1HtpasswdLine("ops", "second")+"\n" {
		t.Fatalf("htpasswd not rewritten: %q", ht)
	}
}

func TestPrepareLocksOpenAutogenWithoutWipingModels(t *testing.T) {
	dir := t.TempDir()
	p := testPaths(dir)
	open := []byte(`# leftover open auto-gen
config:
  database:
    url: sqlite:///config/data.db
gateways:
  default:
    port: 4000
ui:
  gateways:
  - default
llm:
  models:
  - name: gpt-4o-mini
    provider: openAI
    params:
      apiKey: $OPENAI_API_KEY
`)
	if err := os.WriteFile(p.configFile, open, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := prepare(p, mapGetenv(map[string]string{"UI_PASSWORD": "s3cret"})); err != nil {
		t.Fatal(err)
	}
	cfg, err := os.ReadFile(p.configFile)
	if err != nil {
		t.Fatal(err)
	}
	if !hasUIBasicAuth(cfg) {
		t.Fatalf("open auto-gen was not locked:\n%s", cfg)
	}
	if !strings.Contains(string(cfg), "gpt-4o-mini") {
		t.Fatalf("model was wiped during lock:\n%s", cfg)
	}
}

func TestPrepareLeavesExistingBasicAuth(t *testing.T) {
	dir := t.TempDir()
	p := testPaths(dir)
	existing := []byte(`gateways:
  default:
    port: 4000
ui:
  gateways: [default]
  policies:
    basicAuth:
      mode: strict
      htpasswd:
        file: /config/.htpasswd
      realm: custom-realm
`)
	if err := os.WriteFile(p.configFile, existing, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := prepare(p, mapGetenv(map[string]string{"UI_PASSWORD": "s3cret"})); err != nil {
		t.Fatal(err)
	}
	cfg, err := os.ReadFile(p.configFile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(cfg), "custom-realm") {
		t.Fatalf("existing basicAuth realm was rewritten:\n%s", cfg)
	}
}

func TestPrepareLeavesOIDCProtectedUI(t *testing.T) {
	dir := t.TempDir()
	p := testPaths(dir)
	existing := []byte(`gateways:
  default:
    port: 4000
ui:
  gateways: [default]
  policies:
    oidc:
      issuer: https://idp.example.com
      clientId: agentgateway-ui
      clientSecret: $UI_CLIENT_SECRET
      redirectURI: https://example.com/oauth/callback
`)
	if err := os.WriteFile(p.configFile, existing, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := prepare(p, mapGetenv(map[string]string{"UI_PASSWORD": "s3cret"})); err != nil {
		t.Fatal(err)
	}
	cfg, err := os.ReadFile(p.configFile)
	if err != nil {
		t.Fatal(err)
	}
	if hasUIBasicAuth(cfg) {
		t.Fatalf("should not inject basicAuth next to OIDC:\n%s", cfg)
	}
	if !strings.Contains(string(cfg), "idp.example.com") {
		t.Fatalf("OIDC config was rewritten:\n%s", cfg)
	}
}

func TestPrepareRejectsMissingPassword(t *testing.T) {
	dir := t.TempDir()
	err := prepare(testPaths(dir), mapGetenv(nil))
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "UI_PASSWORD") {
		t.Fatalf("error %q should mention UI_PASSWORD", err)
	}
}

func testPaths(dir string) paths {
	return paths{
		configDir:  dir,
		configFile: filepath.Join(dir, "config.yaml"),
		htpasswd:   filepath.Join(dir, ".htpasswd"),
	}
}

func mapGetenv(m map[string]string) func(string) string {
	return func(k string) string {
		if m == nil {
			return ""
		}
		return m[k]
	}
}
