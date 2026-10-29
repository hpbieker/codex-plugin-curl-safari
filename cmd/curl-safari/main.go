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
	Op          string `json:"op"`
	Domain      string `json:"domain"`
	URL         string `json:"url,omitempty"`
	CookieScope string `json:"cookie_scope,omitempty"`
}

type fetchResponse struct {
	OK          bool   `json:"ok"`
	CookieJar   string `json:"cookie_jar,omitempty"`
	Error       string `json:"error,omitempty"`
	ServerPID   int    `json:"server_pid,omitempty"`
	CookieScope string `json:"cookie_scope,omitempty"`
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
	req := fetchRequest{Op: "fetch", Domain: domain, URL: requestURL, CookieScope: "host"}
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
	if resp.CookieScope != "host" {
		return "", errors.New("helper does not support redirect cookies; rebuild and restart CurlSafariServer.app")
	}
	return resp.CookieJar, nil
}

// Read option arity from the curl we will actually invoke, so new options do
// not require a second, potentially outdated option list in this wrapper.
func curlOptionArguments() (map[string]bool, error) {
	output, err := exec.Command("curl", "-q", "--help", "all").Output()
	if err != nil {
		return nil, fmt.Errorf("could not read curl options: %w", err)
	}
	options := make(map[string]bool)
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		for index, field := range fields {
			if !strings.HasPrefix(field, "--") {
				continue
			}
			// Most parameters use <value>; proxies use [protocol://]host[:port].
			takesArgument := index+1 < len(fields) && (strings.HasPrefix(fields[index+1], "<") || strings.HasPrefix(fields[index+1], "["))
			options[field] = takesArgument
			if index == 1 && strings.HasSuffix(fields[0], ",") {
				options[strings.TrimSuffix(fields[0], ",")] = takesArgument
			}
			break
		}
	}
	if !options["--url"] || !options["--data"] {
		return nil, errors.New("could not recognize curl option help")
	}
	return options, nil
}

func findURL(args []string) (string, error) {
	requestURL, _, err := findURLAndArgs(args)
	return requestURL, err
}

func findURLAndArgs(args []string) (string, []string, error) {
	options, err := curlOptionArguments()
	if err != nil {
		return "", nil, err
	}
	positionalOnly := false
	for index := 0; index < len(args); index++ {
		arg := args[index]
		if !positionalOnly && arg == "--" {
			positionalOnly = true
			continue
		}
		if !positionalOnly && strings.HasPrefix(arg, "--") {
			option, value, attached := strings.Cut(arg, "=")
			takesArgument, known := options[option]
			if !known && strings.HasPrefix(option, "--no-") {
				baseTakesArgument, baseKnown := options["--"+strings.TrimPrefix(option, "--no-")]
				known = baseKnown && !baseTakesArgument
			}
			if !known {
				return "", nil, fmt.Errorf("unrecognized curl option: %s", option)
			}
			if takesArgument && !attached {
				index++
				if index == len(args) {
					return "", nil, fmt.Errorf("curl option %s requires a value", option)
				}
				value = args[index]
			}
			if option != "--url" {
				continue
			}
			if attached {
				// Older macOS curl versions require --url and its value as
				// separate arguments. Do not rewrite option values or data.
				normalized := append([]string{}, args[:index]...)
				normalized = append(normalized, "--url", value)
				args = append(normalized, args[index+1:]...)
			}
			arg = value
		} else if !positionalOnly && strings.HasPrefix(arg, "-") && arg != "-" {
			// A short option taking a value consumes the rest of its token,
			// or the following token when no attached value is present.
			for offset := 1; offset < len(arg); offset++ {
				option := "-" + arg[offset:offset+1]
				takesArgument, known := options[option]
				if !known {
					return "", nil, fmt.Errorf("unrecognized curl option: %s", option)
				}
				if takesArgument {
					if offset == len(arg)-1 {
						index++
						if index == len(args) {
							return "", nil, fmt.Errorf("curl option %s requires a value", option)
						}
					}
					break
				}
			}
			continue
		}
		if strings.HasPrefix(arg, "http://") || strings.HasPrefix(arg, "https://") {
			return arg, args, nil
		}
		return "", nil, errors.New("the first request URL must be an explicit http(s) URL")
	}
	return "", nil, errors.New("could not find an http(s) URL in curl arguments")
}

func cookieCurlArgs(args []string) []string {
	prefix := []string{}
	// curl checks only its first argument for -q/--disable, including -q
	// followed by other short options. Preserve that check before inserting -b.
	if len(args) > 0 && (strings.HasPrefix(args[0], "-q") || args[0] == "--disable") {
		prefix = append(prefix, "-q")
	}
	prefix = append(prefix, "-b", "/dev/fd/3")
	return append(prefix, args...)
}

func runCurlWithCookieJar(jar string, curlArgs []string) int {
	reader, writer, err := os.Pipe()
	if err != nil {
		fmt.Fprintf(os.Stderr, "curl-safari: could not create cookie pipe: %v\n", err)
		return 1
	}
	defer reader.Close()

	cmd := exec.Command("curl", cookieCurlArgs(curlArgs)...)
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

	requestURL, curlArgs, err := findURLAndArgs(curlArgs)
	if err != nil {
		fmt.Fprintf(os.Stderr, "curl-safari: %v\n", err)
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
