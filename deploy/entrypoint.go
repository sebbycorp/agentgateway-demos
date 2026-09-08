// Entrypoint for the PaaS image. The official agentgateway image has no
// shell, so this static binary prepares /config then execs the gateway.
package main

import (
	"crypto/sha1"
	"encoding/base64"
	"fmt"
	"os"
	"strings"
	"syscall"

	"gopkg.in/yaml.v3"
)

const (
	defaultUIUser    = "admin"
	htpasswdFilePath = "/config/.htpasswd"
	agentgatewayBin  = "/app/agentgateway"
)

// Seed is the Render lab shape (same as 34-render-deploy-agw/config.example.yaml).
// First boot always writes UI basicAuth. llm and mcp are added only when their
// env vars are set — agentgateway exits if config.yaml expands a missing $VAR,
// and llm.models is required whenever llm is present.
// File-based htpasswd only: inline bcrypt hashes contain $ and the gateway
// env-expands $VARS ($OPENAI_API_KEY, $GITHUB_PERSONAL_ACCESS_TOKEN).
const seedConfig = `# yaml-language-server: $schema=https://agentgateway.dev/schema/config
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
llm:
  gateways: [default]
  policies:
    apiKey:
      mode: strict
      keys:
      - key: sk-lab-admin-...
        metadata:
          name: admin
      - key: sk-lab-demo-...
        metadata:
          name: demo
        allowedModels:
        - gpt-4.1-nano
        - gpt-4.1
        - gpt-4o
      - key: sk-lab-limited-...
        metadata:
          name: limited
        allowedModels:
        - gpt-4.1-nano
        budgets:
        - name: tokens
          limit:
            unit: Tokens
            amount: 1000
          window:
            rolling: 1h
          onBudgetExceeded: Block
  models:
  - name: '*'
    provider: openAI
    params:
      apiKey: $OPENAI_API_KEY
mcp:
  gateways: [default]
  targets:
  - name: github
    mcp:
      host: https://api.githubcopilot.com/mcp/
    policies:
      backendAuth:
        key:
          value: $GITHUB_PERSONAL_ACCESS_TOKEN
# Stdio MCP is optional. Attach to the default gateway — Render only
# publishes :4000, so do not add a separate mcp port:
#   - name: server-everything
#     stdio:
#       cmd: npx
#       args: ["-y", "@modelcontextprotocol/server-everything"]
# Set provider keys in the PaaS dashboard. Never commit them.
`

type paths struct {
	configDir  string
	configFile string
	htpasswd   string
}

func defaultPaths() paths {
	return paths{
		configDir:  "/config",
		configFile: "/config/config.yaml",
		htpasswd:   "/config/.htpasswd",
	}
}

func sha1HtpasswdLine(user, password string) string {
	sum := sha1.Sum([]byte(password))
	return user + ":{SHA}" + base64.StdEncoding.EncodeToString(sum[:])
}

func credentialsFromEnv(getenv func(string) string) (string, string, error) {
	user := strings.TrimSpace(getenv("UI_USER"))
	if user == "" {
		user = defaultUIUser
	}
	if strings.ContainsAny(user, ":\n\r") {
		return "", "", fmt.Errorf("UI_USER must not contain ':' or newlines")
	}
	password := strings.TrimRight(getenv("UI_PASSWORD"), "\r\n")
	if password == "" {
		return "", "", fmt.Errorf("UI_PASSWORD is required to protect the UI; set it in the platform dashboard")
	}
	return user, password, nil
}

func asMap(v any) (map[string]any, bool) {
	m, ok := v.(map[string]any)
	return m, ok
}

func mapOrCreate(parent map[string]any, key string) map[string]any {
	if existing, ok := asMap(parent[key]); ok {
		return existing
	}
	created := map[string]any{}
	parent[key] = created
	return created
}

func hasAuthPolicy(policies map[string]any) bool {
	for _, key := range []string{"basicAuth", "oidc", "jwtAuth", "apiKey", "extAuthz"} {
		if _, ok := policies[key]; ok {
			return true
		}
	}
	return false
}

func hasUIBasicAuth(raw []byte) bool {
	var doc map[string]any
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		return false
	}
	ui, ok := asMap(doc["ui"])
	if !ok {
		return false
	}
	policies, ok := asMap(ui["policies"])
	if !ok {
		return false
	}
	_, ok = policies["basicAuth"]
	return ok
}

func missingSection(doc map[string]any, key string) bool {
	v, ok := doc[key]
	return !ok || v == nil
}

type seedOpts struct {
	includeLLM bool
	includeMCP bool
}

func envPresent(getenv func(string) string, key string) bool {
	return strings.TrimSpace(getenv(key)) != ""
}

func optsFromEnv(getenv func(string) string) seedOpts {
	return seedOpts{
		includeLLM: envPresent(getenv, "OPENAI_API_KEY"),
		includeMCP: envPresent(getenv, "GITHUB_PERSONAL_ACCESS_TOKEN"),
	}
}

func labSectionsFromSeed() (any, any, error) {
	var doc map[string]any
	if err := yaml.Unmarshal([]byte(seedConfig), &doc); err != nil {
		return nil, nil, fmt.Errorf("parse seed config: %w", err)
	}
	return doc["llm"], doc["mcp"], nil
}

func seedConfigBytes(opts seedOpts) ([]byte, error) {
	if opts.includeLLM && opts.includeMCP {
		return []byte(seedConfig), nil
	}
	var doc map[string]any
	if err := yaml.Unmarshal([]byte(seedConfig), &doc); err != nil {
		return nil, fmt.Errorf("parse seed config: %w", err)
	}
	if !opts.includeLLM {
		delete(doc, "llm")
	}
	if !opts.includeMCP {
		delete(doc, "mcp")
	}
	out, err := yaml.Marshal(doc)
	if err != nil {
		return nil, err
	}
	return out, nil
}

func llmModels(doc map[string]any) []any {
	llm, ok := asMap(doc["llm"])
	if !ok {
		return nil
	}
	models, _ := llm["models"].([]any)
	return models
}

func envRefName(s string) (string, bool) {
	s = strings.TrimSpace(s)
	if strings.HasPrefix(s, "${") && strings.HasSuffix(s, "}") && len(s) > 3 {
		return s[2 : len(s)-1], true
	}
	if strings.HasPrefix(s, "$") && len(s) > 1 && !strings.ContainsAny(s[1:], " ${}") {
		return s[1:], true
	}
	return "", false
}

func isUnsetEnvRef(s string, getenv func(string) string) bool {
	name, ok := envRefName(s)
	if !ok {
		return false
	}
	return !envPresent(getenv, name)
}

func unsetStringOrValue(v any, getenv func(string) string) bool {
	switch t := v.(type) {
	case string:
		return isUnsetEnvRef(t, getenv)
	case map[string]any:
		if s, ok := t["value"].(string); ok {
			return isUnsetEnvRef(s, getenv)
		}
	}
	return false
}

func modelUsesUnsetKey(model any, getenv func(string) string) bool {
	m, ok := asMap(model)
	if !ok {
		return false
	}
	if params, ok := asMap(m["params"]); ok && unsetStringOrValue(params["apiKey"], getenv) {
		return true
	}
	if unsetStringOrValue(m["auth"], getenv) {
		return true
	}
	if auth, ok := asMap(m["auth"]); ok {
		if unsetStringOrValue(auth["key"], getenv) {
			return true
		}
		if key, ok := asMap(auth["key"]); ok && unsetStringOrValue(key["value"], getenv) {
			return true
		}
	}
	return false
}

func targetUsesUnsetKey(target any, getenv func(string) string) bool {
	t, ok := asMap(target)
	if !ok {
		return false
	}
	policies, ok := asMap(t["policies"])
	if !ok {
		return false
	}
	backendAuth, ok := asMap(policies["backendAuth"])
	if !ok {
		return false
	}
	if unsetStringOrValue(backendAuth["key"], getenv) {
		return true
	}
	if key, ok := asMap(backendAuth["key"]); ok && unsetStringOrValue(key["value"], getenv) {
		return true
	}
	return false
}

// sanitizeUnsetProviderRefs drops llm models and mcp targets that expand a
// $VAR the process does not have. If that leaves llm with no models, drop
// the whole llm section — the schema requires llm.models whenever llm exists.
func sanitizeUnsetProviderRefs(raw []byte, getenv func(string) string) ([]byte, bool, error) {
	var doc map[string]any
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		return nil, false, fmt.Errorf("parse %s: %w", "config.yaml", err)
	}
	if doc == nil {
		return raw, false, nil
	}
	changed := false

	if _, ok := asMap(doc["llm"]); ok {
		kept := make([]any, 0)
		stripped := false
		for _, model := range llmModels(doc) {
			if modelUsesUnsetKey(model, getenv) {
				stripped = true
				continue
			}
			kept = append(kept, model)
		}
		if len(kept) == 0 {
			delete(doc, "llm")
			changed = true
		} else if stripped {
			llm, _ := asMap(doc["llm"])
			llm["models"] = kept
			changed = true
		}
	}

	if mcp, ok := asMap(doc["mcp"]); ok {
		targets, _ := mcp["targets"].([]any)
		kept := make([]any, 0, len(targets))
		mcpChanged := false
		for _, target := range targets {
			if targetUsesUnsetKey(target, getenv) {
				mcpChanged = true
				continue
			}
			kept = append(kept, target)
		}
		if len(kept) == 0 {
			delete(doc, "mcp")
			changed = changed || mcpChanged || len(targets) == 0
		} else if mcpChanged {
			mcp["targets"] = kept
			changed = true
		}
	}

	if !changed {
		return raw, false, nil
	}
	out, err := yaml.Marshal(doc)
	if err != nil {
		return nil, false, err
	}
	return out, true, nil
}

// ensureLabConfig adds llm/mcp from the seed only when the matching env var is
// set and the disk does not already have that section. It does not overwrite
// models or MCP the operator set in the UI.
func ensureLabConfig(raw []byte, opts seedOpts) ([]byte, bool, error) {
	var doc map[string]any
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		return nil, false, fmt.Errorf("parse %s: %w", "config.yaml", err)
	}
	if doc == nil {
		seed, err := seedConfigBytes(opts)
		if err != nil {
			return nil, false, err
		}
		return seed, true, nil
	}

	needLLM := opts.includeLLM && (missingSection(doc, "llm") || len(llmModels(doc)) == 0)
	needMCP := opts.includeMCP && missingSection(doc, "mcp")
	if !needLLM && !needMCP {
		return raw, false, nil
	}

	llm, mcp, err := labSectionsFromSeed()
	if err != nil {
		return nil, false, err
	}
	if needLLM {
		if missingSection(doc, "llm") {
			doc["llm"] = llm
		} else if seedLLM, ok := asMap(llm); ok {
			existing := mapOrCreate(doc, "llm")
			existing["models"] = seedLLM["models"]
		}
	}
	if needMCP {
		doc["mcp"] = mcp
	}

	out, err := yaml.Marshal(doc)
	if err != nil {
		return nil, false, err
	}
	return out, true, nil
}

func ensureProtectedUI(raw []byte, opts seedOpts) ([]byte, bool, error) {
	var doc map[string]any
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		return nil, false, fmt.Errorf("parse %s: %w", "config.yaml", err)
	}
	if doc == nil {
		seed, err := seedConfigBytes(opts)
		if err != nil {
			return nil, false, err
		}
		return seed, true, nil
	}
	if _, ok := asMap(doc["gateways"]); !ok {
		seed, err := seedConfigBytes(opts)
		if err != nil {
			return nil, false, err
		}
		return seed, true, nil
	}

	ui := mapOrCreate(doc, "ui")
	if policies, ok := asMap(ui["policies"]); ok && hasAuthPolicy(policies) {
		return raw, false, nil
	}
	if _, ok := ui["gateways"]; !ok {
		ui["gateways"] = []any{"default"}
	}
	policies := mapOrCreate(ui, "policies")
	policies["basicAuth"] = map[string]any{
		"mode": "strict",
		"htpasswd": map[string]any{
			"file": htpasswdFilePath,
		},
		"realm": "agentgateway",
	}

	out, err := yaml.Marshal(doc)
	if err != nil {
		return nil, false, err
	}
	return out, true, nil
}

func prepare(p paths, getenv func(string) string) error {
	user, password, err := credentialsFromEnv(getenv)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(p.configDir, 0o755); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}

	line := sha1HtpasswdLine(user, password) + "\n"
	if err := os.WriteFile(p.htpasswd, []byte(line), 0o600); err != nil {
		return fmt.Errorf("write htpasswd: %w", err)
	}

	opts := optsFromEnv(getenv)

	raw, err := os.ReadFile(p.configFile)
	if err != nil {
		if !os.IsNotExist(err) {
			return fmt.Errorf("read config: %w", err)
		}
		seed, err := seedConfigBytes(opts)
		if err != nil {
			return err
		}
		if err := os.WriteFile(p.configFile, seed, 0o644); err != nil {
			return fmt.Errorf("write seed config: %w", err)
		}
		fmt.Fprintf(os.Stderr, "entrypoint: seeded %s (%s)\n", p.configFile, seedSummary(opts))
		return nil
	}

	updated, changed, err := ensureProtectedUI(raw, opts)
	if err != nil {
		return err
	}
	lab, labChanged, err := ensureLabConfig(updated, opts)
	if err != nil {
		return err
	}
	sanitized, sanChanged, err := sanitizeUnsetProviderRefs(lab, getenv)
	if err != nil {
		return err
	}
	if changed || labChanged || sanChanged {
		if err := os.WriteFile(p.configFile, sanitized, 0o644); err != nil {
			return fmt.Errorf("update config: %w", err)
		}
		fmt.Fprintf(os.Stderr, "entrypoint: updated %s (uiAuth=%v lab=%v sanitize=%v)\n", p.configFile, changed, labChanged, sanChanged)
	}
	return nil
}

func seedSummary(opts seedOpts) string {
	parts := []string{"ui basicAuth"}
	if opts.includeLLM {
		parts = append(parts, "llm")
	}
	if opts.includeMCP {
		parts = append(parts, "mcp")
	}
	return strings.Join(parts, " + ")
}

func main() {
	if err := prepare(defaultPaths(), os.Getenv); err != nil {
		fmt.Fprintf(os.Stderr, "entrypoint: %v\n", err)
		os.Exit(1)
	}
	args := []string{agentgatewayBin, "-f", "/config/config.yaml"}
	if err := syscall.Exec(agentgatewayBin, args, os.Environ()); err != nil {
		fmt.Fprintf(os.Stderr, "entrypoint: exec %s: %v\n", agentgatewayBin, err)
		os.Exit(1)
	}
}
