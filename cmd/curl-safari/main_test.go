package main

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

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
			Path:      "/private/tmp/curl-safari/example.com.cookies",
			ServerPID: 123,
		})
	}()

	path, err := requestCookieJar(
		"example.com",
		"https://example.com/account",
		600,
		2*time.Second,
	)
	if err != nil {
		t.Fatal(err)
	}
	if path != "/private/tmp/curl-safari/example.com.cookies" {
		t.Fatalf("unexpected cookie jar path: %s", path)
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
