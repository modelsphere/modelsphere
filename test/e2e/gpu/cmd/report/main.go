package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

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
		input   string
		summary string
		ctx     report.WorkflowContext
	)
	fs.StringVar(&input, "input", "", "path to Ginkgo JSON report file (-ginkgo.json-report)")
	fs.StringVar(&summary, "summary", "", "path to append Markdown summary (defaults to stdout)")
	fs.StringVar(&ctx.StepOutcome, "step-outcome", "", "e2e step outcome")
	fs.StringVar(&ctx.JobStatus, "job-status", "", "workflow job status")
	fs.StringVar(&ctx.RunURL, "run-url", "", "workflow run URL")
	fs.StringVar(&ctx.Ref, "ref", "", "git ref name")
	fs.StringVar(&ctx.SHA, "sha", "", "git commit SHA")
	fs.StringVar(&ctx.Event, "event", "", "workflow trigger event")

	if err := fs.Parse(args); err != nil {
		return err
	}

	var md string
	if input == "" {
		md = report.RenderFallbackMarkdown(ctx, "No Ginkgo JSON report was produced by the e2e suite (the e2e step was skipped, crashed, or timed out before writing -ginkgo.json-report).")
	} else if reports, err := report.ReadJSON(input); err == nil {
		md = report.RenderMarkdown(reports, ctx)
	} else if errors.Is(err, os.ErrNotExist) {
		md = report.RenderFallbackMarkdown(ctx, "No Ginkgo JSON report was produced by the e2e suite (the e2e step was skipped, crashed, or timed out before writing -ginkgo.json-report).")
	} else {
		md = report.RenderFallbackMarkdown(ctx, fmt.Sprintf("Could not read Ginkgo JSON report %s: %v", input, err))
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
	return f.Close()
}
