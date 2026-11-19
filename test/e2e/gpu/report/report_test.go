package report

import (
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/onsi/ginkgo/v2/reporters"
	"github.com/onsi/ginkgo/v2/types"
)

func TestGenerateAndReadGinkgoJSONRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "e2e-gpu-report.json")
	start := time.Date(2026, 11, 19, 2, 0, 0, 0, time.UTC)
	end := start.Add(14*time.Minute + 22*time.Second)

	rep := types.Report{
		SuiteDescription: "modelsphere gpu e2e",
		SuiteSucceeded:   true,
		StartTime:        start,
		EndTime:          end,
		RunTime:          end.Sub(start),
		SpecReports: types.SpecReports{
			{
				LeafNodeType: types.NodeTypeBeforeSuite,
				State:        types.SpecStatePassed,
				StartTime:    start,
				EndTime:      start.Add(45 * time.Second),
				RunTime:      45 * time.Second,
				ReportEntries: types.ReportEntries{
					{
						Name: RunConfigEntryName,
						Value: types.WrapEntryValue(RunConfig{
							HelmEnv:     "test-gpu",
							KubeContext: "gpu-ctx",
							Model:       "qwen3-8b",
							Variant:     "vllm-tp1-a100",
							ServedName:  "Qwen3-8B",
							Release:     "e2e-gpu",
							Namespace:   "llm-demo",
							Backend:     "helm",
							Catalog:     "https://modelsphere.github.io/model-catalog/",
							GPUCount:    1,
							GPUProducts: []string{"NVIDIA-A100-SXM4-80GB"},
						}),
					},
				},
			},
			{
				ContainerHierarchyTexts: []string{"stack", "swissd"},
				LeafNodeType:            types.NodeTypeIt,
				LeafNodeText:            "deploys the model",
				State:                   types.SpecStatePassed,
				StartTime:               start.Add(45 * time.Second),
				EndTime:                 end,
				RunTime:                 end.Sub(start.Add(45 * time.Second)),
				SpecEvents: types.SpecEvents{
					{
						SpecEventType:    types.SpecEventByStart,
						Message:          "planning",
						TimelineLocation: types.TimelineLocation{Time: start.Add(45 * time.Second)},
					},
					{
						SpecEventType:    types.SpecEventByEnd,
						Message:          "planning",
						Duration:         2500 * time.Millisecond,
						TimelineLocation: types.TimelineLocation{Time: start.Add(47500 * time.Millisecond)},
					},
					{
						SpecEventType:    types.SpecEventByStart,
						Message:          "installing",
						TimelineLocation: types.TimelineLocation{Time: start.Add(48 * time.Second)},
					},
				},
			},
			{
				LeafNodeType: types.NodeTypeReportAfterSuite,
				State:        types.SpecStatePassed,
				RunTime:      time.Millisecond,
			},
		},
	}

	if err := reporters.GenerateJSONReport(rep, path); err != nil {
		t.Fatalf("GenerateJSONReport: %v", err)
	}
	got, err := ReadJSON(path)
	if err != nil {
		t.Fatalf("ReadJSON: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want 1 report, got %d", len(got))
	}
	if !got[0].SuiteSucceeded || got[0].SuiteDescription != rep.SuiteDescription {
		t.Fatalf("unexpected decoded header: %+v", got[0])
	}
	cfg := extractRunConfig(got[0].SpecReports)
	if cfg.Model != "qwen3-8b" || len(cfg.GPUProducts) != 1 || cfg.GPUProducts[0] != "NVIDIA-A100-SXM4-80GB" {
		t.Fatalf("unexpected decoded run config: %+v", cfg)
	}
	steps := extractSteps(got[0].SpecReports[1])
	if len(steps) != 2 || steps[0].DurationSeconds != 2.5 {
		t.Fatalf("unexpected decoded steps: %+v", steps)
	}
}

func TestFormatDuration(t *testing.T) {
	cases := []struct {
		sec  float64
		want string
	}{
		{0, "0s"},
		{-1, "0s"},
		{0.0001, "<1ms"},
		{0.45, "450ms"},
		{12.34, "12.3s"},
		{862, "14m 22s"},
		{3725, "1h 02m 05s"},
	}
	for _, tc := range cases {
		if got := FormatDuration(tc.sec); got != tc.want {
			t.Errorf("FormatDuration(%v) = %q, want %q", tc.sec, got, tc.want)
		}
	}
}

func TestRenderMarkdownPassed(t *testing.T) {
	start := time.Date(2026, 11, 19, 2, 0, 0, 0, time.UTC)
	end := start.Add(14*time.Minute + 22*time.Second)

	path := filepath.Join(t.TempDir(), "report.json")
	rep := types.Report{
		SuiteDescription: "modelsphere gpu e2e",
		SuiteSucceeded:   true,
		StartTime:        start,
		EndTime:          end,
		RunTime:          end.Sub(start),
		SpecReports: types.SpecReports{
			{
				LeafNodeType: types.NodeTypeBeforeSuite,
				State:        types.SpecStatePassed,
				RunTime:      65 * time.Second,
				ReportEntries: types.ReportEntries{
					{
						Name: RunConfigEntryName,
						Value: types.WrapEntryValue(RunConfig{
							HelmEnv:     "test-gpu",
							KubeContext: "gpu-cluster",
							Model:       "qwen3-8b",
							Variant:     "vllm-tp1-a100",
							ServedName:  "Qwen3-8B",
							Release:     "e2e-gpu",
							Namespace:   "llm-demo",
							Backend:     "helm",
							Catalog:     "https://modelsphere.github.io/model-catalog/",
							GPUCount:    1,
							GPUProducts: []string{"NVIDIA-A100-SXM4-80GB"},
						}),
					},
				},
			},
			{
				ContainerHierarchyTexts: []string{"stack", "swissd"},
				LeafNodeType:            types.NodeTypeIt,
				LeafNodeText:            "deploys the model on a GPU",
				State:                   types.SpecStatePassed,
				StartTime:               start.Add(65 * time.Second),
				EndTime:                 start.Add(825 * time.Second),
				RunTime:                 760 * time.Second,
				SpecEvents: types.SpecEvents{
					{
						SpecEventType:    types.SpecEventByStart,
						Message:          "planning qwen3-8b",
						TimelineLocation: types.TimelineLocation{Time: start.Add(65 * time.Second)},
					},
					{
						SpecEventType:    types.SpecEventByEnd,
						Message:          "planning qwen3-8b",
						Duration:         1500 * time.Millisecond,
						TimelineLocation: types.TimelineLocation{Time: start.Add(66500 * time.Millisecond)},
					},
					{
						SpecEventType:    types.SpecEventByStart,
						Message:          "installing with backend helm",
						TimelineLocation: types.TimelineLocation{Time: start.Add(67 * time.Second)},
					},
					{
						SpecEventType:    types.SpecEventByEnd,
						Message:          "installing with backend helm",
						Duration:         12200 * time.Millisecond,
						TimelineLocation: types.TimelineLocation{Time: start.Add(79200 * time.Millisecond)},
					},
				},
			},
			{
				LeafNodeType: types.NodeTypeAfterSuite,
				State:        types.SpecStatePassed,
				RunTime:      30 * time.Second,
			},
			{
				LeafNodeType: types.NodeTypeReportAfterSuite,
				State:        types.SpecStatePassed,
				RunTime:      time.Millisecond,
			},
		},
	}

	if err := reporters.GenerateJSONReport(rep, path); err != nil {
		t.Fatalf("GenerateJSONReport: %v", err)
	}
	reports, err := ReadJSON(path)
	if err != nil {
		t.Fatalf("ReadJSON: %v", err)
	}

	ctx := WorkflowContext{
		StepOutcome: "success",
		JobStatus:   "success",
		RunURL:      "https://github.com/modelsphere/modelsphere/actions/runs/42",
		Ref:         "main",
		SHA:         "abcdef1234567890",
		Event:       "workflow_dispatch",
	}

	md := RenderMarkdown(reports, ctx)
	checks := []string{
		"## ✅ GPU E2E Report: PASSED",
		"**1/1** specs passed · **14m 22s**",
		"`test-gpu` (context: `gpu-cluster`)",
		"`qwen3-8b / vllm-tp1-a100` (servedName: `Qwen3-8B`)",
		"sha: `abcdef1`",
		"[View run](https://github.com/modelsphere/modelsphere/actions/runs/42)",
		"| 1 | 0 | 0 | 0 | 1 |",
		"### Suite Lifecycle",
		"| BeforeSuite | ✅ passed | 1m 05s |",
		"| AfterSuite | ✅ passed | 30.0s |",
		"### Specs",
		"<summary>Step timings</summary>",
		"- planning qwen3-8b — 1.5s",
		"- installing with backend helm — 12.2s",
	}
	for _, want := range checks {
		if !strings.Contains(md, want) {
			t.Errorf("missing %q in markdown:\n%s", want, md)
		}
	}
	if strings.Contains(md, "### Failures") {
		t.Errorf("did not expect Failures section for passing report:\n%s", md)
	}
	if strings.Contains(md, "ReportAfterSuite") {
		t.Errorf("did not expect ReportAfterSuite in rendered lifecycle table:\n%s", md)
	}
}

func TestRenderMarkdownFailedWithEscapingAndTruncation(t *testing.T) {
	t0 := time.Date(2026, 11, 19, 2, 0, 0, 0, time.UTC)
	longBody := strings.Repeat("A", 100) + "\n```\nembedded fence\n```\n" + strings.Repeat("A", 2900) + strings.Repeat("Z", 2000)

	rep := types.Report{
		SuiteDescription:           "modelsphere gpu e2e",
		SuiteSucceeded:             false,
		RunTime:                    90100 * time.Millisecond,
		SpecialSuiteFailureReasons: []string{"Suite Timeout Elapsed"},
		SpecReports: types.SpecReports{
			{
				ContainerHierarchyTexts: []string{"stack | swissd"},
				LeafNodeType:            types.NodeTypeIt,
				LeafNodeText:            "deploys model",
				State:                   types.SpecStateFailed,
				StartTime:               t0,
				EndTime:                 t0.Add(90100 * time.Millisecond),
				RunTime:                 90100 * time.Millisecond,
				LeafNodeLocation: types.CodeLocation{
					FileName:   "/home/runner/work/modelsphere/test/e2e/gpu/e2e_test.go",
					LineNumber: 103,
				},
				SpecEvents: types.SpecEvents{
					{
						SpecEventType:    types.SpecEventByStart,
						Message:          "installing with backend helm",
						TimelineLocation: types.TimelineLocation{Time: t0.Add(30100 * time.Millisecond)},
					},
				},
				Failure: types.Failure{
					Message:        longBody,
					ForwardedPanic: "boom",
					Location: types.CodeLocation{
						FileName:   "/home/runner/work/modelsphere/test/e2e/gpu/helpers_test.go",
						LineNumber: 92,
					},
					FailureNodeType: types.NodeTypeIt,
				},
				AdditionalFailures: []types.AdditionalFailure{
					{
						State: types.SpecStateFailed,
						Failure: types.Failure{
							Message:         "409 conflict",
							FailureNodeType: types.NodeTypeCleanupAfterEach,
							Location: types.CodeLocation{
								FileName:   "/home/runner/work/modelsphere/test/e2e/gpu/helpers_test.go",
								LineNumber: 128,
							},
						},
					},
				},
			},
			{
				ContainerHierarchyTexts: []string{"stack"},
				LeafNodeType:            types.NodeTypeIt,
				LeafNodeText:            "logs in",
				State:                   types.SpecStatePassed,
				RunTime:                 1200 * time.Millisecond,
			},
		},
	}

	md := RenderMarkdown([]types.Report{rep}, WorkflowContext{StepOutcome: "failure"})
	checks := []string{
		"## ❌ GPU E2E Report: FAILED",
		"**1/2** specs failed (**1** passed) · **1m 30s**",
		"- **Suite failure:** Suite Timeout Elapsed",
		"Location: `test/e2e/gpu/e2e_test.go:103`",
		"Last step: `installing with backend helm`",
		"... (truncated ",
		"````text",
		"Panic:",
		"<summary>Additional failures (1)</summary>",
		"- **DeferCleanup (Each)** (`failed`) at `test/e2e/gpu/helpers_test.go:128`",
		"409 conflict",
		`| stack \| swissd deploys model | ❌ failed | 1m 30s |`,
	}
	for _, want := range checks {
		if !strings.Contains(md, want) {
			t.Errorf("missing %q in markdown:\n%s", want, md)
		}
	}

	if strings.Index(md, "### Failures") > strings.Index(md, "### Specs") {
		t.Errorf("expected Failures section before Specs table")
	}
}

func TestRenderMarkdownBeforeSuiteFailureAndMismatchAndEmpty(t *testing.T) {
	beforeFail := types.Report{
		SuiteDescription: "modelsphere gpu e2e",
		SuiteSucceeded:   false,
		RunTime:          15 * time.Second,
		SpecReports: types.SpecReports{
			{
				LeafNodeType: types.NodeTypeBeforeSuite,
				State:        types.SpecStateFailed,
				RunTime:      15 * time.Second,
				LeafNodeLocation: types.CodeLocation{
					FileName:   "/home/runner/work/modelsphere/test/e2e/gpu/e2e_suite_test.go",
					LineNumber: 128,
				},
				Failure: types.Failure{
					FailureNodeType: types.NodeTypeBeforeSuite,
					Message:         "kubectl get nodes failed",
				},
			},
		},
	}
	md := RenderMarkdown([]types.Report{beforeFail}, WorkflowContext{StepOutcome: "failure"})
	if !strings.Contains(md, "Suite failed outside spec assertions (**0/0** specs passed)") {
		t.Errorf("expected hook failure summary, got:\n%s", md)
	}
	if !strings.Contains(md, "kubectl get nodes failed") {
		t.Errorf("expected BeforeSuite error message in Failures section:\n%s", md)
	}

	mismatch := types.Report{
		SuiteDescription: "modelsphere gpu e2e",
		SuiteSucceeded:   true,
		RunTime:          5 * time.Second,
		SpecReports: types.SpecReports{
			{
				LeafNodeType: types.NodeTypeIt,
				LeafNodeText: "ok",
				State:        types.SpecStatePassed,
				RunTime:      5 * time.Second,
			},
		},
	}
	md2 := RenderMarkdown([]types.Report{mismatch}, WorkflowContext{StepOutcome: "failure"})
	if !strings.Contains(md2, "## ❌ GPU E2E Report: FAILED") || !strings.Contains(md2, "> [!WARNING]") {
		t.Errorf("expected mismatch warning and FAILED header, got:\n%s", md2)
	}

	emptyMD := RenderMarkdown(nil, WorkflowContext{StepOutcome: "failure", JobStatus: "failure"})
	if !strings.Contains(emptyMD, "## ❌ GPU E2E Report: FAILED") || !strings.Contains(emptyMD, "contained no suite reports") {
		t.Errorf("expected fallback for empty report slice, got:\n%s", emptyMD)
	}
}

func TestRenderFallbackMarkdown(t *testing.T) {
	cases := []struct {
		name     string
		ctx      WorkflowContext
		wantHead string
	}{
		{
			name:     "skipped",
			ctx:      WorkflowContext{StepOutcome: "skipped", JobStatus: "failure"},
			wantHead: "## ⏭️ GPU E2E Report: SKIPPED",
		},
		{
			name:     "cancelled",
			ctx:      WorkflowContext{StepOutcome: "cancelled", JobStatus: "cancelled"},
			wantHead: "## 🚫 GPU E2E Report: CANCELLED",
		},
		{
			name:     "failed",
			ctx:      WorkflowContext{StepOutcome: "failure", JobStatus: "failure", SHA: "1234567890"},
			wantHead: "## ❌ GPU E2E Report: FAILED",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			md := RenderFallbackMarkdown(tc.ctx, "No Ginkgo JSON report produced.")
			if !strings.Contains(md, tc.wantHead) {
				t.Errorf("got:\n%s\nwant heading %q", md, tc.wantHead)
			}
		})
	}
}
