package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const rootDir = "/private/tmp/curl-safari"

var requestDir = filepath.Join(rootDir, "requests")
var responseDir = filepath.Join(rootDir, "responses")

type fetchRequest struct {
	Op         string `json:"op"`
	Domain     string `json:"domain"`
	URL        string `json:"url,omitempty"`
	TTLSeconds int    `json:"ttl_seconds"`
}

type fetchResponse struct {
	OK        bool   `json:"ok"`
	Path      string `json:"path,omitempty"`
	Error     string `json:"error,omitempty"`
	ServerPID int    `json:"server_pid,omitempty"`
}

func usage() {
	fmt.Fprintln(os.Stderr, "curl-safari: try 'curl-safari --help' or 'curl-safari --manual' for more information")
	os.Exit(2)
}

func isCurlMetaCommand(args []string) bool {
	if len(args) == 0 {
		return false
	}
	switch args[0] {
	case "-h", "--help", "-M", "--manual", "-V", "--version":
		return true
	default:
		return false
	}
}

func runCurlMetaCommand(args []string) {
	cmd := exec.Command("curl", args...)
	cmd.Stdin = os.Stdin
	if args[0] == "-h" || args[0] == "--help" {
		output, err := cmd.Output()
		if len(output) > 0 {
			text := strings.Replace(string(output), "Usage: curl ", "Usage: curl-safari ", 1)
			fmt.Fprint(os.Stdout, text)
		}
		if err != nil {
			if exitErr, ok := err.(*exec.ExitError); ok {
				if len(exitErr.Stderr) > 0 {
					_, _ = os.Stderr.Write(exitErr.Stderr)
				}
				os.Exit(exitErr.ExitCode())
			}
			fmt.Fprintf(os.Stderr, "curl-safari: %v\n", err)
			os.Exit(1)
		}
		return
	}
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			os.Exit(exitErr.ExitCode())
		}
		fmt.Fprintf(os.Stderr, "curl-safari: %v\n", err)
		os.Exit(1)
	}
}

func randomID() (string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

func ensureDirs() error {
	for _, dir := range []string{rootDir, requestDir, responseDir} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
		_ = os.Chmod(dir, 0o700)
	}
	return nil
}

func writeAtomic(path string, data []byte, mode os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	_ = os.Chmod(tmp, mode)
	return os.Rename(tmp, path)
}

func requestCookieJar(domain, requestURL string, ttl int, timeout time.Duration) (string, error) {
	if err := ensureDirs(); err != nil {
		return "", err
	}
	id, err := randomID()
	if err != nil {
		return "", err
	}
	req := fetchRequest{Op: "fetch", Domain: domain, URL: requestURL, TTLSeconds: ttl}
	data, err := json.Marshal(req)
	if err != nil {
		return "", err
	}

	reqPath := filepath.Join(requestDir, id+".request.json")
	respPath := filepath.Join(responseDir, id+".response.json")
	if err := writeAtomic(reqPath, append(data, '\n'), 0o600); err != nil {
		return "", err
	}
	defer os.Remove(reqPath)

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		respData, err := os.ReadFile(respPath)
		if err == nil {
			_ = os.Remove(respPath)
			var resp fetchResponse
			if err := json.Unmarshal(respData, &resp); err != nil {
				return "", err
			}
			if !resp.OK {
				if resp.ServerPID != 0 {
					return "", fmt.Errorf("%s [server pid %d]", resp.Error, resp.ServerPID)
				}
				return "", errors.New(resp.Error)
			}
			if resp.Path == "" {
				return "", errors.New("server returned empty cookie jar path")
			}
			return resp.Path, nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return "", err
		}
		time.Sleep(100 * time.Millisecond)
	}
	return "", fmt.Errorf("server did not respond within %s; start it with: open -a CurlSafariServer.app", timeout)
}

func findURL(args []string) string {
	for _, arg := range args {
		if strings.HasPrefix(arg, "http://") || strings.HasPrefix(arg, "https://") {
			return arg
		}
	}
	return ""
}

func main() {
	ttl := 600
	fetchTimeout := 10 * time.Second
	curlArgs := os.Args[1:]
	if len(curlArgs) == 0 {
		usage()
	}
	if isCurlMetaCommand(curlArgs) {
		runCurlMetaCommand(curlArgs)
		return
	}

	requestURL := findURL(curlArgs)
	if requestURL == "" {
		fmt.Fprintln(os.Stderr, "curl-safari: could not find an http(s) URL in curl arguments")
		os.Exit(2)
	}
	parsed, err := url.Parse(requestURL)
	if err != nil || parsed.Hostname() == "" {
		fmt.Fprintf(os.Stderr, "curl-safari: URL has no host: %s\n", requestURL)
		os.Exit(2)
	}

	jar, err := requestCookieJar(parsed.Hostname(), requestURL, ttl, fetchTimeout)
	if err != nil {
		fmt.Fprintf(os.Stderr, "curl-safari: %v\n", err)
		os.Exit(1)
	}

	cmd := exec.Command("curl", append([]string{"-b", jar}, curlArgs...)...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			os.Exit(exitErr.ExitCode())
		}
		fmt.Fprintf(os.Stderr, "curl-safari: %v\n", err)
		os.Exit(1)
	}
}
