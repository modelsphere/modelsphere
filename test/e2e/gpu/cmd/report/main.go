package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/onsi/ginkgo/v2/types"

	"github.com/modelsphere/modelsphere/test/e2e/gpu/report"
)

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "report: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("report", flag.ContinueOnError)
	fs.SetOutput(io.Discard)

	var (
		input        string
		summary      string
		htmlPath     string
		uploadHTML   string
		uploadServer string
		uploadUser   string
		ctx          report.WorkflowContext
	)
	fs.StringVar(&input, "input", "", "path to Ginkgo JSON report file (-ginkgo.json-report)")
	fs.StringVar(&summary, "summary", "", "path to append Markdown summary (defaults to stdout when -html is unset)")
	fs.StringVar(&htmlPath, "html", "", "path to write standalone HTML report")
	fs.StringVar(&uploadHTML, "upload-html", "", "path to HTML report to upload if -upload-server is set (errors are non-fatal)")
	fs.StringVar(&uploadServer, "upload-server", os.Getenv("E2E_REPORT_SERVER_URL"), "internal HTTP file server base URL (dufs)")
	fs.StringVar(&uploadUser, "upload-user", os.Getenv("E2E_REPORT_USER"), "HTTP Basic auth username for internal report server (defaults to ci)")
	fs.StringVar(&ctx.StepOutcome, "step-outcome", os.Getenv("E2E_STEP_OUTCOME"), "e2e step outcome")
	fs.StringVar(&ctx.JobStatus, "job-status", os.Getenv("E2E_JOB_STATUS"), "workflow job status")
	fs.StringVar(&ctx.RunURL, "run-url", defaultRunURL(), "workflow run URL")
	fs.StringVar(&ctx.ArtifactURL, "artifact-url", os.Getenv("E2E_ARTIFACT_URL"), "uploaded report artifact URL")
	fs.StringVar(&ctx.ReportURL, "report-url", os.Getenv("E2E_REPORT_URL"), "internal HTML report URL")
	fs.StringVar(&ctx.Ref, "ref", os.Getenv("GITHUB_REF_NAME"), "git ref name")
	fs.StringVar(&ctx.SHA, "sha", os.Getenv("GITHUB_SHA"), "git commit SHA")
	fs.StringVar(&ctx.Event, "event", os.Getenv("GITHUB_EVENT_NAME"), "workflow trigger event")

	if err := fs.Parse(args); err != nil {
		return err
	}

	var (
		reports        []types.Report
		fallbackReason string
	)
	if input == "" {
		fallbackReason = "No Ginkgo JSON report was produced by the e2e suite (the e2e step was skipped, crashed, or timed out before writing -ginkgo.json-report)."
	} else {
		var err error
		reports, err = report.ReadJSON(input)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				fallbackReason = "No Ginkgo JSON report was produced by the e2e suite (the e2e step was skipped, crashed, or timed out before writing -ginkgo.json-report)."
			} else {
				fallbackReason = fmt.Sprintf("Could not read Ginkgo JSON report %s: %v", input, err)
			}
		}
	}

	if htmlPath != "" {
		var (
			html string
			err  error
		)
		if fallbackReason != "" {
			html, err = report.RenderFallbackHTML(ctx, fallbackReason)
		} else {
			html, err = report.RenderHTML(reports, ctx)
		}
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(htmlPath), 0o755); err != nil {
			return fmt.Errorf("create html dir: %w", err)
		}
		if err := os.WriteFile(htmlPath, []byte(html), 0o644); err != nil {
			return fmt.Errorf("write html %s: %w", htmlPath, err)
		}
	}

	if uploadHTML != "" && strings.TrimSpace(uploadServer) != "" && ctx.ReportURL == "" {
		uploadedURL, err := report.UploadHTML(
			context.Background(),
			uploadHTML,
			uploadServer,
			uploadUser,
			os.Getenv("E2E_REPORT_TOKEN"),
			os.Getenv("GITHUB_RUN_ID"),
		)
		if err != nil {
			fmt.Fprintf(os.Stderr, "warning: internal html upload failed: %v\n", err)
			ctx.ReportUploadError = err.Error()
		} else if uploadedURL != "" {
			ctx.ReportURL = uploadedURL
		}
	}

	if summary != "" || htmlPath == "" {
		var md string
		if fallbackReason != "" {
			md = report.RenderFallbackMarkdown(ctx, fallbackReason)
		} else {
			md = report.RenderMarkdown(reports, ctx)
		}
		if !strings.HasSuffix(md, "\n") {
			md += "\n"
		}
		if summary == "" {
			_, err := io.WriteString(stdout, md)
			return err
		}
		if err := os.MkdirAll(filepath.Dir(summary), 0o755); err != nil {
			return fmt.Errorf("create summary dir: %w", err)
		}
		f, err := os.OpenFile(summary, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			return fmt.Errorf("open summary %s: %w", summary, err)
		}
		if _, err := io.WriteString(f, md); err != nil {
			_ = f.Close()
			return fmt.Errorf("write summary %s: %w", summary, err)
		}
		if err := f.Close(); err != nil {
			return err
		}
	}

	return nil
}

func defaultRunURL() string {
	server := strings.TrimRight(os.Getenv("GITHUB_SERVER_URL"), "/")
	repo := strings.Trim(os.Getenv("GITHUB_REPOSITORY"), "/")
	runID := os.Getenv("GITHUB_RUN_ID")
	if server == "" || repo == "" || runID == "" {
		return ""
	}
	return fmt.Sprintf("%s/%s/actions/runs/%s", server, repo, runID)
}
