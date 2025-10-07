package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/getsops/sops/v3/decrypt"
	"github.com/mozilla-services/yaml"
	"github.com/joho/godotenv"
	"gopkg.in/ini.v1"
)

type FormatType string

const (
	Yaml   FormatType = "yaml"
	JSON   FormatType = "json"
	Binary FormatType = "binary"
	Dotenv FormatType = "dotenv"
	INI    FormatType = "ini"
)

func main() {
	var (
		sopsFile   = flag.String("file", "", "Path to the sops encrypted file")
		key        = flag.String("key", "", "Key to extract from the decrypted content")
		format     = flag.String("format", "yaml", "Format of the sops file (yaml, json, binary, dotenv, ini)")
		gnupgHome  = flag.String("gnupg-home", "", "GPG home directory")
		ageKeyFile = flag.String("age-key-file", "", "Age key file path")
		sshKeyPath = flag.String("ssh-key-path", "", "SSH key path")
		output     = flag.String("output", "", "Output file path (default: stdout)")
	)
	flag.Parse()

	if *sopsFile == "" {
		fmt.Fprintf(os.Stderr, "Error: --file is required\n")
		os.Exit(1)
	}

	// Set environment variables for sops
	if *gnupgHome != "" {
		os.Setenv("GNUPGHOME", *gnupgHome)
	}
	if *ageKeyFile != "" {
		os.Setenv("SOPS_AGE_KEY_FILE", *ageKeyFile)
	}
	if *sshKeyPath != "" {
		os.Setenv("SOPS_SSH_KEY_PATH", *sshKeyPath)
	}

	// Read the encrypted file
	data, err := os.ReadFile(*sopsFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading sops file: %v\n", err)
		os.Exit(1)
	}

	// Decrypt the file
	decrypted, err := decrypt.Data(data, FormatType(*format))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error decrypting file: %v\n", err)
		os.Exit(1)
	}

	var result interface{}

	// Parse based on format and extract key
	switch FormatType(*format) {
	case Binary:
		if *key != "" {
			fmt.Fprintf(os.Stderr, "Warning: --key is ignored for binary format\n")
		}
		result = string(decrypted)
	case Yaml, JSON:
		var yamlData map[string]interface{}
		if err := yaml.Unmarshal(decrypted, &yamlData); err != nil {
			fmt.Fprintf(os.Stderr, "Error parsing YAML/JSON: %v\n", err)
			os.Exit(1)
		}

		if *key == "" {
			// Return the whole object as JSON
			result = yamlData
		} else {
			// Extract specific key
			value, err := extractKey(yamlData, *key)
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error extracting key '%s': %v\n", *key, err)
				os.Exit(1)
			}
			result = value
		}
	case Dotenv:
		envMap, err := godotenv.Unmarshal(string(decrypted))
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error parsing dotenv: %v\n", err)
			os.Exit(1)
		}

		if *key == "" {
			result = envMap
		} else {
			if value, exists := envMap[*key]; exists {
				result = value
			} else {
				fmt.Fprintf(os.Stderr, "Key '%s' not found in dotenv file\n", *key)
				os.Exit(1)
			}
		}
	case INI:
		cfg, err := ini.Load(decrypted)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error parsing INI: %v\n", err)
			os.Exit(1)
		}

		if *key == "" {
			// Return all sections and keys as a map
			result = cfg.MapTo(map[string]interface{}{})
		} else {
			// Key format: section.key or just key for default section
			section, keyName := parseINIKey(*key)
			sectionObj := cfg.Section(section)
			if sectionObj == nil {
				fmt.Fprintf(os.Stderr, "Section '%s' not found in INI file\n", section)
				os.Exit(1)
			}

			if keyObj := sectionObj.Key(keyName); keyObj != nil {
				result = keyObj.String()
			} else {
				fmt.Fprintf(os.Stderr, "Key '%s' not found in section '%s'\n", keyName, section)
				os.Exit(1)
			}
		}
	default:
		fmt.Fprintf(os.Stderr, "Unsupported format: %s\n", *format)
		os.Exit(1)
	}

	// Output the result
	var outputData []byte
	if strResult, ok := result.(string); ok {
		outputData = []byte(strResult)
	} else {
		outputData, err = json.MarshalIndent(result, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error marshaling result: %v\n", err)
			os.Exit(1)
		}
	}

	if *output != "" {
		// Ensure output directory exists
		if err := os.MkdirAll(filepath.Dir(*output), 0755); err != nil {
			fmt.Fprintf(os.Stderr, "Error creating output directory: %v\n", err)
			os.Exit(1)
		}

		if err := os.WriteFile(*output, outputData, 0644); err != nil {
			fmt.Fprintf(os.Stderr, "Error writing output: %v\n", err)
			os.Exit(1)
		}
	} else {
		fmt.Print(string(outputData))
	}
}

// extractKey extracts a value from a nested map using dot notation
func extractKey(data map[string]interface{}, key string) (interface{}, error) {
	keys := parseKey(key)
	current := data

	for i, k := range keys[:len(keys)-1] {
		if next, ok := current[k].(map[string]interface{}); ok {
			current = next
		} else {
			return nil, fmt.Errorf("key path '%s' not found", strings.Join(keys[:i+1], "."))
		}
	}

	if value, ok := current[keys[len(keys)-1]]; ok {
		return value, nil
	}

	return nil, fmt.Errorf("key '%s' not found", key)
}

// parseKey splits a dot notation key into components
func parseKey(key string) []string {
	// Simple split on dots - this could be enhanced for escaped dots
	return strings.Split(key, ".")
}

// parseINIKey parses an INI key in format "section.key" or "key" for default section
func parseINIKey(key string) (section, keyName string) {
	if strings.Contains(key, ".") {
		parts := strings.SplitN(key, ".", 2)
		return parts[0], parts[1]
	}
	return "", key
}