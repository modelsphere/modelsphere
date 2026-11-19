package report

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

const uploadTimeout = 15 * time.Second

// UploadHTML uploads filePath via HTTP PUT to a dufs/WebDAV-compatible server.
// If filePath does not exist or serverURL is empty, it returns ("", nil).
func UploadHTML(ctx context.Context, filePath, serverURL, user, token, runID string) (string, error) {
	return uploadHTMLWithClient(ctx, &http.Client{Timeout: uploadTimeout}, filePath, serverURL, user, token, runID)
}

func uploadHTMLWithClient(ctx context.Context, client *http.Client, filePath, serverURL, user, token, runID string) (string, error) {
	serverURL = strings.TrimSpace(serverURL)
	if filePath == "" || serverURL == "" {
		return "", nil
	}

	f, err := os.Open(filePath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", nil
		}
		return "", fmt.Errorf("open html report %s: %w", filePath, err)
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		return "", fmt.Errorf("stat html report %s: %w", filePath, err)
	}

	name := reportFileName(runID)
	targetURL := strings.TrimRight(serverURL, "/") + "/e2e-gpu/" + name

	reqCtx, cancel := context.WithTimeout(ctx, uploadTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodPut, targetURL, f)
	if err != nil {
		return "", fmt.Errorf("build upload request: %w", err)
	}
	req.ContentLength = info.Size()
	req.Header.Set("Content-Type", "text/html; charset=utf-8")

	if token != "" {
		user = strings.TrimSpace(user)
		switch {
		case user != "":
			req.SetBasicAuth(user, token)
		case strings.Contains(token, ":"):
			u, pass, _ := strings.Cut(token, ":")
			req.SetBasicAuth(u, pass)
		default:
			req.SetBasicAuth("ci", token)
		}
	}

	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("upload html report to %s: %w", targetURL, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode/100 != 2 {
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return "", fmt.Errorf("upload html report to %s returned %s: %s",
			targetURL, resp.Status, strings.TrimSpace(string(snippet)))
	}

	return targetURL, nil
}

func reportFileName(runID string) string {
	clean := strings.TrimSpace(runID)
	clean = strings.ReplaceAll(clean, "/", "-")
	if clean == "" {
		clean = time.Now().UTC().Format("20060102-150405")
	}
	return clean + ".html"
}
