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

// Seed matches official empty-/config auto-gen plus ui.policies.basicAuth.
// File-based htpasswd only: inline bcrypt hashes contain $ and the gateway
// env-expands $VARS in config.yaml.
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

func ensureProtectedUI(raw []byte) ([]byte, bool, error) {
	var doc map[string]any
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		return nil, false, fmt.Errorf("parse %s: %w", "config.yaml", err)
	}
	if doc == nil {
		return []byte(seedConfig), true, nil
	}
	if _, ok := asMap(doc["gateways"]); !ok {
		return []byte(seedConfig), true, nil
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

	raw, err := os.ReadFile(p.configFile)
	if err != nil {
		if !os.IsNotExist(err) {
			return fmt.Errorf("read config: %w", err)
		}
		if err := os.WriteFile(p.configFile, []byte(seedConfig), 0o644); err != nil {
			return fmt.Errorf("write seed config: %w", err)
		}
		return nil
	}

	updated, changed, err := ensureProtectedUI(raw)
	if err != nil {
		return err
	}
	if changed {
		if err := os.WriteFile(p.configFile, updated, 0o644); err != nil {
			return fmt.Errorf("update config: %w", err)
		}
	}
	return nil
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
