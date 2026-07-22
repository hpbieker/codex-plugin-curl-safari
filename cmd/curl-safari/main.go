package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"time"
)

const (
	defaultSocketPath    = "/private/tmp/curl-safari.sock"
	maximumResponseBytes = 1_048_576
)

type fetchRequest struct {
	Op     string `json:"op"`
	Domain string `json:"domain"`
	URL    string `json:"url,omitempty"`
}

type fetchResponse struct {
	OK        bool   `json:"ok"`
	CookieJar string `json:"cookie_jar,omitempty"`
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

func serverSocketPath() string {
	if path := os.Getenv("CURL_SAFARI_SOCKET_PATH"); path != "" {
		return path
	}
	return defaultSocketPath
}

func requestCookieJar(domain, requestURL string, timeout time.Duration) (string, error) {
	req := fetchRequest{Op: "fetch", Domain: domain, URL: requestURL}
	socketPath := serverSocketPath()
	connection, err := net.DialTimeout("unix", socketPath, timeout)
	if err != nil {
		return "", fmt.Errorf(
			"server is unavailable at %s: %w; start it with: open -a CurlSafariServer.app",
			socketPath,
			err,
		)
	}
	defer connection.Close()
	if err := connection.SetDeadline(time.Now().Add(timeout)); err != nil {
		return "", err
	}

	if err := json.NewEncoder(connection).Encode(req); err != nil {
		return "", err
	}

	var resp fetchResponse
	limitedResponse := io.LimitReader(connection, maximumResponseBytes+1)
	if err := json.NewDecoder(limitedResponse).Decode(&resp); err != nil {
		return "", fmt.Errorf("invalid response from server: %w", err)
	}
	if !resp.OK {
		if resp.ServerPID != 0 {
			return "", fmt.Errorf("%s [server pid %d]", resp.Error, resp.ServerPID)
		}
		return "", errors.New(resp.Error)
	}
	if resp.CookieJar == "" {
		return "", errors.New("server returned empty cookie jar")
	}
	return resp.CookieJar, nil
}

func findURL(args []string) string {
	for _, arg := range args {
		if strings.HasPrefix(arg, "http://") || strings.HasPrefix(arg, "https://") {
			return arg
		}
	}
	return ""
}

func runCurlWithCookieJar(jar string, curlArgs []string) int {
	reader, writer, err := os.Pipe()
	if err != nil {
		fmt.Fprintf(os.Stderr, "curl-safari: could not create cookie pipe: %v\n", err)
		return 1
	}
	defer reader.Close()

	cmd := exec.Command("curl", append([]string{"-b", "/dev/fd/3"}, curlArgs...)...)
	cmd.ExtraFiles = []*os.File{reader}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		writer.Close()
		fmt.Fprintf(os.Stderr, "curl-safari: %v\n", err)
		return 1
	}
	reader.Close()
	go func() {
		_, _ = io.WriteString(writer, jar)
		_ = writer.Close()
	}()
	if err := cmd.Wait(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return exitErr.ExitCode()
		}
		fmt.Fprintf(os.Stderr, "curl-safari: %v\n", err)
		return 1
	}
	return 0
}

func main() {
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

	jar, err := requestCookieJar(parsed.Hostname(), requestURL, fetchTimeout)
	if err != nil {
		fmt.Fprintf(os.Stderr, "curl-safari: %v\n", err)
		os.Exit(1)
	}
	os.Exit(runCurlWithCookieJar(jar, curlArgs))
}
