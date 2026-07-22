package main

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

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
	if exitCode := runCurlWithCookieJar(jar, []string{"-sS", server.URL}); exitCode != 0 {
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
		if request.Op != "fetch" || request.Domain != "example.com" {
			serverError <- &unexpectedRequestError{request: request}
			return
		}
		serverError <- json.NewEncoder(connection).Encode(fetchResponse{
			OK:        true,
			CookieJar: "# Netscape HTTP Cookie File\n.example.com\tTRUE\t/\tTRUE\t0\tsession\tsecret\n",
			ServerPID: 123,
		})
	}()

	jar, err := requestCookieJar(
		"example.com",
		"https://example.com/account",
		600,
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

type unexpectedRequestError struct {
	request fetchRequest
}

func (err *unexpectedRequestError) Error() string {
	data, _ := json.Marshal(err.request)
	return "unexpected request: " + string(data)
}
