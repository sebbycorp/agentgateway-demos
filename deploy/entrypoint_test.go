package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
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

func TestCredentialsTrimsPasswordNewlines(t *testing.T) {
	_, pass, err := credentialsFromEnv(func(k string) string {
		if k == "UI_PASSWORD" {
			return "s3cret\n"
		}
		return ""
	})
	if err != nil {
		t.Fatal(err)
	}
	if pass != "s3cret" {
		t.Fatalf("password = %q, want trimmed s3cret", pass)
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

func TestSeedConfigIncludesLabLLMAndHTTPGithubMCP(t *testing.T) {
	if !hasUIBasicAuth([]byte(seedConfig)) {
		t.Fatal("seedConfig missing basicAuth")
	}
	var doc map[string]any
	if err := yaml.Unmarshal([]byte(seedConfig), &doc); err != nil {
		t.Fatalf("seedConfig is not valid YAML: %v", err)
	}
	llm, ok := asMap(doc["llm"])
	if !ok {
		t.Fatal("seedConfig missing llm")
	}
	models, ok := llm["models"].([]any)
	if !ok || len(models) == 0 {
		t.Fatal("seedConfig missing llm.models")
	}
	mcp, ok := asMap(doc["mcp"])
	if !ok {
		t.Fatal("seedConfig missing mcp")
	}
	targets, ok := mcp["targets"].([]any)
	if !ok || len(targets) == 0 {
		t.Fatal("seedConfig missing mcp.targets")
	}
	github, ok := asMap(targets[0])
	if !ok {
		t.Fatal("seedConfig mcp.targets[0] is not a map")
	}
	if github["name"] != "github" {
		t.Fatalf("mcp target name = %v, want github", github["name"])
	}
	if _, ok := github["stdio"]; ok {
		t.Fatal("seedConfig must not start stdio MCP on first boot")
	}
	host, ok := asMap(github["mcp"])
	if !ok {
		t.Fatal("github target missing mcp.host")
	}
	if host["host"] != "https://api.githubcopilot.com/mcp/" {
		t.Fatalf("github host = %v", host["host"])
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
	if !hasUIBasicAuth(cfg) {
		t.Fatalf("seed config missing basicAuth:\n%s", cfg)
	}
	if !strings.Contains(string(cfg), "file: /config/.htpasswd") {
		t.Fatalf("seed config should use file-based htpasswd:\n%s", cfg)
	}
	if !strings.Contains(string(cfg), "mode: strict") {
		t.Fatalf("seed config should set mode strict:\n%s", cfg)
	}
	if !strings.Contains(string(cfg), "apiKey: $OPENAI_API_KEY") {
		t.Fatalf("seed config should wire OpenAI from env:\n%s", cfg)
	}
	if !strings.Contains(string(cfg), "https://api.githubcopilot.com/mcp/") {
		t.Fatalf("seed config should include GitHub MCP:\n%s", cfg)
	}
	if !strings.Contains(string(cfg), "sk-lab-admin-...") {
		t.Fatalf("seed config should include lab virtual keys:\n%s", cfg)
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
	if !strings.Contains(string(cfg), "api.githubcopilot.com") {
		t.Fatalf("missing lab MCP was not merged:\n%s", cfg)
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
	if !strings.Contains(string(cfg), "apiKey: $OPENAI_API_KEY") {
		t.Fatalf("UI-only config was not filled with lab llm:\n%s", cfg)
	}
	if !strings.Contains(string(cfg), "api.githubcopilot.com") {
		t.Fatalf("UI-only config was not filled with lab mcp:\n%s", cfg)
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

func TestPrepareMergesLabIntoEmptySeed(t *testing.T) {
	dir := t.TempDir()
	p := testPaths(dir)
	oldSeed := []byte(`# leftover UI-only seed
config:
  database:
    url: sqlite:///config/data.db
gateways:
  default:
    port: 4000
ui:
  gateways: [default]
  policies:
    basicAuth:
      mode: strict
      htpasswd:
        file: /config/.htpasswd
      realm: agentgateway
`)
	if err := os.WriteFile(p.configFile, oldSeed, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := prepare(p, mapGetenv(map[string]string{"UI_PASSWORD": "s3cret"})); err != nil {
		t.Fatal(err)
	}
	cfg, err := os.ReadFile(p.configFile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(cfg), "apiKey: $OPENAI_API_KEY") {
		t.Fatalf("empty seed was not filled with llm:\n%s", cfg)
	}
	if !strings.Contains(string(cfg), "sk-lab-limited-...") {
		t.Fatalf("empty seed was not filled with virtual keys:\n%s", cfg)
	}
	if !strings.Contains(string(cfg), "api.githubcopilot.com") {
		t.Fatalf("empty seed was not filled with mcp:\n%s", cfg)
	}
	if !hasUIBasicAuth(cfg) {
		t.Fatalf("merge dropped basicAuth:\n%s", cfg)
	}
}

func TestPrepareDoesNotOverwriteExistingLLMAndMCP(t *testing.T) {
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
      realm: agentgateway
llm:
  gateways: [default]
  models:
  - name: gpt-4o-mini
    provider: openAI
    params:
      apiKey: $OPENAI_API_KEY
mcp:
  gateways: [default]
  targets:
  - name: custom
    mcp:
      host: https://example.com/mcp
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
	if !strings.Contains(string(cfg), "gpt-4o-mini") {
		t.Fatalf("existing model was overwritten:\n%s", cfg)
	}
	if strings.Contains(string(cfg), "api.githubcopilot.com") {
		t.Fatalf("existing mcp was overwritten with lab github:\n%s", cfg)
	}
	if !strings.Contains(string(cfg), "https://example.com/mcp") {
		t.Fatalf("custom mcp target was dropped:\n%s", cfg)
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
