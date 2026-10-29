package main

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

func TestCLIForwardsAttachedURLToSystemCurl(t *testing.T) {
	directory, err := os.MkdirTemp("/private/tmp", "curl-safari-cli-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	executable := filepath.Join(directory, "curl-safari")
	if output, err := exec.Command("go", "build", "-o", executable, ".").CombinedOutput(); err != nil {
		t.Fatalf("build CLI: %v\n%s", err, output)
	}
	socketPath := filepath.Join(directory, "server.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	t.Setenv("CURL_SAFARI_SOCKET_PATH", socketPath)
	serverError := make(chan error, 1)
	go func() {
		connection, err := listener.Accept()
		if err != nil {
			serverError <- err
			return
		}
		defer connection.Close()
		var request fetchRequest
		if err := json.NewDecoder(connection).Decode(&request); err != nil {
			serverError <- err
			return
		}
		if request.Domain != "127.0.0.1" || request.CookieScope != "host" {
			serverError <- &unexpectedRequestError{request: request}
			return
		}
		serverError <- json.NewEncoder(connection).Encode(fetchResponse{
			OK: true, CookieScope: "host",
			CookieJar: "# Netscape HTTP Cookie File\n127.0.0.1\tFALSE\t/\tFALSE\t0\tsession\tsynthetic\n",
		})
	}()
	received := make(chan http.Header, 1)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		received <- request.Header.Clone()
		writer.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	cmd := exec.Command(executable, "-q", "-sS", "--max-time", "5", "--noproxy", "*",
		"--referer", "https://another.invalid/", "--url="+server.URL)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("run installed-style CLI: %v\n%s", err, output)
	}
	if err := <-serverError; err != nil {
		t.Fatal(err)
	}
	select {
	case headers := <-received:
		if headers.Get("Referer") != "https://another.invalid/" || headers.Get("Cookie") != "session=synthetic" {
			t.Fatal("CLI did not forward the expected referer and cookie")
		}
	case <-time.After(time.Second):
		t.Fatal("CLI did not reach the HTTP server")
	}
}

func TestRedirectCookiesRespectHostPathAndSecure(t *testing.T) {
	const host = "account.example.test"
	const jar = "# Netscape HTTP Cookie File\n" +
		"account.example.test\tFALSE\t/\tFALSE\t0\thost\tsynthetic\n" +
		"account.example.test\tFALSE\t/account\tFALSE\t0\tpath\tsynthetic\n" +
		"account.example.test\tFALSE\t/\tTRUE\t0\tsecure\tsynthetic\n" +
		".example.test\tTRUE\t/\tFALSE\t0\tshared\tsynthetic\n" +
		".example.test\tTRUE\t/\tTRUE\t0\tsharedsecure\tsynthetic\n" +
		"account.example.test\tFALSE\t/\tFALSE\t1\texpired\tsynthetic\n"
	tests := []struct {
		name, startScheme, endScheme, endHost string
		wantStart, wantEnd                    string
	}{
		{"different path", "http", "http", host, "host,shared", "host,path,shared"},
		{"upgrade to HTTPS", "http", "https", host, "host,shared", "host,path,secure,shared,sharedsecure"},
		{"downgrade to HTTP", "https", "http", host, "host,secure,shared,sharedsecure", "host,path,shared"},
		{"sibling host", "https", "https", "other.example.test", "host,secure,shared,sharedsecure", "shared,sharedsecure"},
		{"unrelated host", "https", "https", "unrelated.test", "host,secure,shared,sharedsecure", ""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			received := make(chan string, 2)
			var destination string
			handler := http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				var names []string
				for _, cookie := range request.Cookies() {
					names = append(names, cookie.Name)
				}
				sort.Strings(names)
				received <- strings.Join(names, ",")
				if request.URL.Path == "/start" {
					http.Redirect(writer, request, destination, http.StatusFound)
				} else {
					writer.WriteHeader(http.StatusNoContent)
				}
			})
			httpServer := httptest.NewServer(handler)
			defer httpServer.Close()
			tlsServer := httptest.NewTLSServer(handler)
			defer tlsServer.Close()
			_, httpPort, _ := net.SplitHostPort(httpServer.Listener.Addr().String())
			_, tlsPort, _ := net.SplitHostPort(tlsServer.Listener.Addr().String())
			ports := map[string]string{"http": httpPort, "https": tlsPort}
			destination = test.endScheme + "://" + test.endHost + ":" + ports[test.endScheme] + "/account"
			start := test.startScheme + "://" + host + ":" + ports[test.startScheme] + "/start"
			args := []string{"-q", "-sS", "-L", "--max-time", "5", "--noproxy", "*", "--insecure"}
			for _, hostname := range []string{host, test.endHost} {
				for _, port := range []string{httpPort, tlsPort} {
					args = append(args, "--resolve", hostname+":"+port+":127.0.0.1")
				}
			}
			args = append(args, start)
			if code := runCurlWithCookieJar(jar, args); code != 0 {
				t.Fatalf("curl exited with status %d", code)
			}
			for index, want := range []string{test.wantStart, test.wantEnd} {
				select {
				case got := <-received:
					if got != want {
						t.Errorf("request %d cookie names = %q; want %q", index, got, want)
					}
				case <-time.After(time.Second):
					t.Fatalf("missing request %d", index)
				}
			}
		})
	}
}

func TestFindURL(t *testing.T) {
	const target = "https://target.example/account"
	tests := []struct {
		name string
		args []string
	}{
		{"positional", []string{target}},
		{"url option", []string{"--url", target}},
		{"attached url option", []string{"--url=" + target}},
		{"referer", []string{"--referer", "https://ref.example/", target}},
		{"short referer", []string{"-e", "https://ref.example/", target}},
		{"attached short referer", []string{"-ehttps://ref.example/", target}},
		{"clustered referer", []string{"-sSe", "https://ref.example/", target}},
		{"attached clustered referer", []string{"-sSehttps://ref.example/", target}},
		{"data", []string{"--data", "https://value.example/", target}},
		{"attached data", []string{"--data=https://value.example/", target}},
		{"short data", []string{"-d", "https://value.example/", target}},
		{"data variants", []string{"--data-raw", "https://value.example/", "--data-urlencode", "https://other.example/", target}},
		{"header", []string{"-H", "https://value.example/", target}},
		{"output", []string{"--output", "https://value.example/", target}},
		{"proxy", []string{"--proxy", "https://proxy.example/", target}},
		{"short proxy", []string{"-x", "https://proxy.example/", target}},
		{"preproxy", []string{"--preproxy", "https://proxy.example/", target}},
		{"boolean flags", []string{"-sSL", "--compressed", "--no-insecure", target}},
		{"end of options", []string{"--", target}},
		{"first transfer", []string{target, "--next", "https://second.example/"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := findURL(test.args)
			if err != nil || got != target {
				t.Fatalf("findURL(%q) = %q, %v; want %q", test.args, got, err, target)
			}
		})
	}
}

func TestFindURLRejectsAmbiguousOrMissingArguments(t *testing.T) {
	for _, args := range [][]string{
		nil,
		{"--url"},
		{"--referer"},
		{"-sSe"},
		{"--data", "https://value.example/"},
		{"--unrecognized-option", "https://value.example/", "https://target.example/"},
		{"-?", "https://target.example/"},
		{"--url=ftp://target.example/", "https://second.example/"},
	} {
		if got, err := findURL(args); err == nil {
			t.Errorf("findURL(%q) = %q without an error", args, got)
		}
	}
}

func TestRunCurlPreservesDisableConfig(t *testing.T) {
	configDirectory := t.TempDir()
	t.Setenv("CURL_HOME", configDirectory)
	if err := os.WriteFile(filepath.Join(configDirectory, ".curlrc"), []byte("header = \"X-From-Curlrc: yes\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name       string
		args       []string
		wantConfig bool
	}{
		{"short disable", []string{"-q"}, false},
		{"long disable", []string{"--disable"}, false},
		{"leading clustered disable", []string{"-qsS"}, false},
		{"default config", nil, true},
		{"late disable", []string{"-s", "-q"}, true},
		{"nonleading clustered disable", []string{"-sq"}, true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			received := make(chan http.Header, 1)
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				received <- request.Header.Clone()
				writer.WriteHeader(http.StatusNoContent)
			}))
			defer server.Close()
			jar := "# Netscape HTTP Cookie File\n127.0.0.1\tFALSE\t/\tFALSE\t0\tsession\tfrom-pipe\n"
			args := append(append([]string{}, test.args...), "-sS", server.URL)
			if code := runCurlWithCookieJar(jar, args); code != 0 {
				t.Fatalf("curl exited with status %d", code)
			}
			select {
			case headers := <-received:
				if got := headers.Get("X-From-Curlrc") == "yes"; got != test.wantConfig {
					t.Errorf("loaded .curlrc = %v; want %v", got, test.wantConfig)
				}
				if !strings.Contains(headers.Get("Cookie"), "session=from-pipe") {
					t.Error("request did not include the cookie from the pipe")
				}
			case <-time.After(time.Second):
				t.Fatal("curl did not reach the test server")
			}
		})
	}
}

func TestRunCurlReadsCookieJarFromPipe(t *testing.T) {
	received := make(chan string, 1)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		cookie, err := request.Cookie("session")
		if err != nil {
			received <- ""
		} else {
			received <- cookie.Value
		}
		writer.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	jar := "# Netscape HTTP Cookie File\n127.0.0.1\tFALSE\t/\tFALSE\t0\tsession\tfrom-pipe\n"
	if exitCode := runCurlWithCookieJar(jar, []string{"-q", "-sS", server.URL}); exitCode != 0 {
		t.Fatalf("curl exited with status %d", exitCode)
	}
	if value := <-received; value != "from-pipe" {
		t.Fatalf("unexpected cookie value received by server: %q", value)
	}
}

func TestRequestCookieJarUsesUnixSocket(t *testing.T) {
	temporaryDirectory, err := os.MkdirTemp("/private/tmp", "curl-safari-go-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(temporaryDirectory) })

	socketPath := filepath.Join(temporaryDirectory, "server.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	t.Setenv("CURL_SAFARI_SOCKET_PATH", socketPath)

	serverError := make(chan error, 1)
	go func() {
		connection, acceptErr := listener.Accept()
		if acceptErr != nil {
			serverError <- acceptErr
			return
		}
		defer connection.Close()

		var request fetchRequest
		if decodeErr := json.NewDecoder(connection).Decode(&request); decodeErr != nil {
			serverError <- decodeErr
			return
		}
		if request.Op != "fetch" || request.Domain != "example.com" || request.CookieScope != "host" {
			serverError <- &unexpectedRequestError{request: request}
			return
		}
		serverError <- json.NewEncoder(connection).Encode(fetchResponse{
			OK:          true,
			CookieJar:   "# Netscape HTTP Cookie File\n.example.com\tTRUE\t/\tTRUE\t0\tsession\tsecret\n",
			ServerPID:   123,
			CookieScope: "host",
		})
	}()

	jar, err := requestCookieJar(
		"example.com",
		"https://example.com/account",
		2*time.Second,
	)
	if err != nil {
		t.Fatal(err)
	}
	if jar != "# Netscape HTTP Cookie File\n.example.com\tTRUE\t/\tTRUE\t0\tsession\tsecret\n" {
		t.Fatal("unexpected cookie jar contents")
	}
	if err := <-serverError; err != nil {
		t.Fatal(err)
	}
}

func TestRequestCookieJarRejectsOldHelper(t *testing.T) {
	directory, err := os.MkdirTemp("/private/tmp", "curl-safari-old-helper-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	path := filepath.Join(directory, "server.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	t.Setenv("CURL_SAFARI_SOCKET_PATH", path)
	done := make(chan error, 1)
	go func() {
		connection, err := listener.Accept()
		if err != nil {
			done <- err
			return
		}
		defer connection.Close()
		var request fetchRequest
		if err := json.NewDecoder(connection).Decode(&request); err != nil {
			done <- err
			return
		}
		done <- json.NewEncoder(connection).Encode(fetchResponse{
			OK: true, CookieJar: "# Netscape HTTP Cookie File\n",
		})
	}()
	if _, err := requestCookieJar("example.test", "https://example.test/", time.Second); err == nil || !strings.Contains(err.Error(), "rebuild and restart") {
		t.Fatalf("expected helper upgrade instructions, got %v", err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

type unexpectedRequestError struct {
	request fetchRequest
}

func (err *unexpectedRequestError) Error() string {
	data, _ := json.Marshal(err.request)
	return "unexpected request: " + string(data)
}
