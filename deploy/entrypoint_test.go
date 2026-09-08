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
	if strings.Contains(string(cfg), "$OPENAI_API_KEY") {
		t.Fatalf("seed config should omit OpenAI model when OPENAI_API_KEY is unset:\n%s", cfg)
	}
	if !llmHasEmptyModels(cfg) {
		t.Fatalf("seed config must keep llm.models (empty list) so the schema is valid:\n%s", cfg)
	}
	if strings.Contains(string(cfg), "api.githubcopilot.com") {
		t.Fatalf("seed config should omit GitHub MCP when GITHUB_PERSONAL_ACCESS_TOKEN is unset:\n%s", cfg)
	}
	if !strings.Contains(string(cfg), "sk-lab-admin-...") {
		t.Fatalf("seed config should include lab virtual keys:\n%s", cfg)
	}
}

func TestPrepareSeedsOpenAIWhenKeySet(t *testing.T) {
	dir := t.TempDir()
	p := testPaths(dir)
	if err := prepare(p, mapGetenv(map[string]string{
		"UI_PASSWORD":    "s3cret",
		"OPENAI_API_KEY": "sk-test",
	})); err != nil {
		t.Fatal(err)
	}
	cfg, err := os.ReadFile(p.configFile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(cfg), "apiKey: $OPENAI_API_KEY") {
		t.Fatalf("seed config should wire OpenAI from env when key is set:\n%s", cfg)
	}
	if strings.Contains(string(cfg), "api.githubcopilot.com") {
		t.Fatalf("GitHub MCP should stay omitted without a PAT:\n%s", cfg)
	}
}

func TestPrepareSeedsGitHubMCPWhenTokenSet(t *testing.T) {
	dir := t.TempDir()
	p := testPaths(dir)
	if err := prepare(p, mapGetenv(map[string]string{
		"UI_PASSWORD":                   "s3cret",
		"GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_lab",
	})); err != nil {
		t.Fatal(err)
	}
	cfg, err := os.ReadFile(p.configFile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(cfg), "https://api.githubcopilot.com/mcp/") {
		t.Fatalf("seed config should include GitHub MCP when token is set:\n%s", cfg)
	}
	if !strings.Contains(string(cfg), "$GITHUB_PERSONAL_ACCESS_TOKEN") {
		t.Fatalf("seed config should wire GitHub MCP from env:\n%s", cfg)
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
	if strings.Contains(string(cfg), "$OPENAI_API_KEY") {
		t.Fatalf("unset $OPENAI_API_KEY model should be stripped so the gateway can start:\n%s", cfg)
	}
	if !llmHasEmptyModels(cfg) {
		t.Fatalf("stripping the last model must leave llm.models: []:\n%s", cfg)
	}
	if strings.Contains(string(cfg), "api.githubcopilot.com") {
		t.Fatalf("GitHub MCP should not merge without GITHUB_PERSONAL_ACCESS_TOKEN:\n%s", cfg)
	}
}

func TestPrepareRestoresEmptyModelsWhenFieldMissing(t *testing.T) {
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
  policies:
    apiKey:
      mode: strict
      keys:
      - key: sk-lab-admin-...
        metadata:
          name: admin
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
	if !llmHasEmptyModels(cfg) {
		t.Fatalf("llm without models must be repaired to models: []:\n%s", cfg)
	}
	if !strings.Contains(string(cfg), "sk-lab-admin-...") {
		t.Fatalf("virtual keys were dropped while repairing models:\n%s", cfg)
	}
}

func TestPrepareKeepsOpenAIModelWhenKeySet(t *testing.T) {
	dir := t.TempDir()
	p := testPaths(dir)
	open := []byte(`gateways:
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
	if err := prepare(p, mapGetenv(map[string]string{
		"UI_PASSWORD":    "s3cret",
		"OPENAI_API_KEY": "sk-test",
	})); err != nil {
		t.Fatal(err)
	}
	cfg, err := os.ReadFile(p.configFile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(cfg), "gpt-4o-mini") {
		t.Fatalf("existing OpenAI model was wiped even though the key is set:\n%s", cfg)
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
	if !strings.Contains(string(cfg), "sk-lab-admin-...") {
		t.Fatalf("UI-only config was not filled with lab virtual keys:\n%s", cfg)
	}
	if strings.Contains(string(cfg), "$OPENAI_API_KEY") {
		t.Fatalf("UI-only config should not gain OpenAI model without OPENAI_API_KEY:\n%s", cfg)
	}
	if strings.Contains(string(cfg), "api.githubcopilot.com") {
		t.Fatalf("UI-only config should not gain GitHub MCP without a token:\n%s", cfg)
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
	if strings.Contains(string(cfg), "$OPENAI_API_KEY") {
		t.Fatalf("empty seed should not gain OpenAI model without OPENAI_API_KEY:\n%s", cfg)
	}
	if !strings.Contains(string(cfg), "sk-lab-limited-...") {
		t.Fatalf("empty seed was not filled with virtual keys:\n%s", cfg)
	}
	if strings.Contains(string(cfg), "api.githubcopilot.com") {
		t.Fatalf("empty seed should not gain GitHub MCP without a token:\n%s", cfg)
	}
	if !hasUIBasicAuth(cfg) {
		t.Fatalf("merge dropped basicAuth:\n%s", cfg)
	}
}

func TestPrepareMergesGitHubMCPWhenTokenAddedLater(t *testing.T) {
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
	if err := prepare(p, mapGetenv(map[string]string{
		"UI_PASSWORD":                   "s3cret",
		"GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_lab",
	})); err != nil {
		t.Fatal(err)
	}
	cfg, err := os.ReadFile(p.configFile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(cfg), "api.githubcopilot.com") {
		t.Fatalf("missing mcp was not merged after token was set:\n%s", cfg)
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
	if strings.Contains(string(cfg), "$OPENAI_API_KEY") {
		t.Fatalf("existing env-ref model should be stripped without OPENAI_API_KEY:\n%s", cfg)
	}
	if strings.Contains(string(cfg), "api.githubcopilot.com") {
		t.Fatalf("existing mcp was overwritten with lab github:\n%s", cfg)
	}
	if !strings.Contains(string(cfg), "https://example.com/mcp") {
		t.Fatalf("custom mcp target was dropped:\n%s", cfg)
	}
}

func TestPrepareMergesOpenAIWhenKeyAddedLater(t *testing.T) {
	dir := t.TempDir()
	p := testPaths(dir)
	oldSeed := []byte(`gateways:
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
	if err := prepare(p, mapGetenv(map[string]string{
		"UI_PASSWORD":    "s3cret",
		"OPENAI_API_KEY": "sk-test",
	})); err != nil {
		t.Fatal(err)
	}
	cfg, err := os.ReadFile(p.configFile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(cfg), "apiKey: $OPENAI_API_KEY") {
		t.Fatalf("missing OpenAI model was not merged after key was set:\n%s", cfg)
	}
}

func TestPrepareStripsAnthropicEnvRefWithoutKey(t *testing.T) {
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
  - name: claude
    provider: anthropic
    params:
      apiKey: $ANTHROPIC_API_KEY
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
	if strings.Contains(string(cfg), "$ANTHROPIC_API_KEY") {
		t.Fatalf("unset $ANTHROPIC_API_KEY model should be stripped:\n%s", cfg)
	}
}

func TestPrepareKeepsLiteralProviderKey(t *testing.T) {
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
  models:
  - name: local
    provider: openAI
    params:
      apiKey: sk-already-in-config
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
	if !strings.Contains(string(cfg), "sk-already-in-config") {
		t.Fatalf("literal provider key was stripped:\n%s", cfg)
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

func llmHasEmptyModels(raw []byte) bool {
	var doc map[string]any
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		return false
	}
	llm, ok := asMap(doc["llm"])
	if !ok {
		return false
	}
	models, ok := llm["models"].([]any)
	return ok && len(models) == 0
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
