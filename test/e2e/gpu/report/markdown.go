package report

import (
	"encoding/json"
	"fmt"
	"math"
	"path/filepath"
	"strings"
	"time"

	"github.com/onsi/ginkgo/v2/types"
)

const maxFailureChars = 4000

type specCounts struct {
	Total   int
	Passed  int
	Failed  int
	Skipped int
	Pending int
}

type stepTiming struct {
	Name            string
	DurationSeconds float64
}

// FormatDuration renders a duration in seconds for human-readable Markdown summaries.
func FormatDuration(seconds float64) string {
	if seconds <= 0 {
		return "0s"
	}
	if seconds < 1 {
		ms := int(math.Round(seconds * 1000))
		if ms == 0 {
			return "<1ms"
		}
		return fmt.Sprintf("%dms", ms)
	}
	if seconds < 60 {
		return fmt.Sprintf("%.1fs", seconds)
	}
	total := int(math.Round(seconds))
	if total < 3600 {
		return fmt.Sprintf("%dm %02ds", total/60, total%60)
	}
	h := total / 3600
	m := (total % 3600) / 60
	s := total % 60
	return fmt.Sprintf("%dh %02dm %02ds", h, m, s)
}

// RenderMarkdown formats Ginkgo JSON reports and workflow metadata into GitHub Flavored Markdown.
func RenderMarkdown(reports []types.Report, ctx WorkflowContext) string {
	if len(reports) == 0 {
		return RenderFallbackMarkdown(ctx, "Ginkgo JSON report contained no suite reports.")
	}

	merged, itSpecs, counts, hooks, runCfg := analyzeReports(reports)

	var b strings.Builder

	passed := merged.SuiteSucceeded && (ctx.StepOutcome == "" || ctx.StepOutcome == "success")
	if passed {
		b.WriteString("## ✅ GPU E2E Report: PASSED\n\n")
	} else {
		b.WriteString("## ❌ GPU E2E Report: FAILED\n\n")
	}

	durSec := merged.RunTime.Seconds()
	dur := FormatDuration(durSec)
	switch {
	case counts.Failed > 0:
		fmt.Fprintf(&b, "**%d/%d** specs failed (**%d** passed) · **%s**\n\n",
			counts.Failed, counts.Total, counts.Passed, dur)
	case !merged.SuiteSucceeded:
		fmt.Fprintf(&b, "Suite failed outside spec assertions (**%d/%d** specs passed) · **%s**\n\n",
			counts.Passed, counts.Total, dur)
	case !passed:
		fmt.Fprintf(&b, "**%d/%d** specs passed, but step outcome was `%s` · **%s**\n\n",
			counts.Passed, counts.Total, ctx.StepOutcome, dur)
	default:
		fmt.Fprintf(&b, "**%d/%d** specs passed · **%s**\n\n",
			counts.Passed, counts.Total, dur)
	}

	if merged.SuiteSucceeded && ctx.StepOutcome != "" && ctx.StepOutcome != "success" {
		fmt.Fprintf(&b, "> [!WARNING]\n> The Ginkgo suite reported success, but the `e2e` workflow step ended with outcome `%s`.\n\n",
			ctx.StepOutcome)
	}

	writeReportLinks(&b, ctx)
	writeMetadataTable(&b, merged, runCfg, durSec, ctx)
	writeCountsTable(&b, counts)

	hasFailures := !passed || len(merged.SpecialSuiteFailureReasons) > 0 || anyFailed(hooks) || anyFailed(itSpecs)
	if hasFailures {
		writeFailuresSection(&b, merged.SpecialSuiteFailureReasons, hooks, itSpecs)
	}

	if len(hooks) > 0 {
		writeSpecTable(&b, "### Suite Lifecycle", "Hook", hooks)
	}
	if len(itSpecs) > 0 {
		writeSpecTable(&b, "### Specs", "Spec", itSpecs)
	}
	writeStepTimings(&b, hooks, itSpecs)

	return b.String()
}

// RenderFallbackMarkdown renders a summary when the JSON report is missing, empty, or unreadable.
func RenderFallbackMarkdown(ctx WorkflowContext, reason string) string {
	var b strings.Builder

	status := fallbackStatus(ctx)
	switch status {
	case "SKIPPED":
		b.WriteString("## ⏭️ GPU E2E Report: SKIPPED\n\n")
	case "CANCELLED":
		b.WriteString("## 🚫 GPU E2E Report: CANCELLED\n\n")
	case "FAILED":
		b.WriteString("## ❌ GPU E2E Report: FAILED\n\n")
	default:
		b.WriteString("## ⚠️ GPU E2E Report: UNKNOWN\n\n")
	}

	if reason != "" {
		fmt.Fprintf(&b, "%s\n\n", strings.TrimSpace(reason))
	}

	writeReportLinks(&b, ctx)

	var rows [][2]string
	if ctx.JobStatus != "" {
		rows = append(rows, [2]string{"Job status", fmt.Sprintf("`%s`", escapeTableCell(ctx.JobStatus))})
	}
	if ctx.StepOutcome != "" {
		rows = append(rows, [2]string{"E2E step outcome", fmt.Sprintf("`%s`", escapeTableCell(ctx.StepOutcome))})
	}
	if wf := formatWorkflowCell(ctx); wf != "" {
		rows = append(rows, [2]string{"Workflow", wf})
	}
	if len(rows) > 0 {
		b.WriteString("### Workflow Metadata\n\n")
		writeKeyValueTable(&b, rows)
	}

	return b.String()
}

func writeReportLinks(b *strings.Builder, ctx WorkflowContext) {
	var links []string
	if u := strings.TrimSpace(ctx.ReportURL); u != "" {
		links = append(links, fmt.Sprintf("[Open HTML report](%s)", u))
	}
	if u := strings.TrimSpace(ctx.ArtifactURL); u != "" {
		links = append(links, fmt.Sprintf("[Download GitHub artifact (.zip)](%s)", u))
	}
	if len(links) > 0 {
		fmt.Fprintf(b, "> [!TIP]\n> **HTML Report:** %s\n\n", strings.Join(links, " · "))
	}
	if msg := strings.TrimSpace(ctx.ReportUploadError); msg != "" {
		fmt.Fprintf(b, "> [!NOTE]\n> Internal HTML server upload failed (e2e result unaffected): `%s`\n\n",
			strings.ReplaceAll(msg, "`", "'"))
	}
}

func analyzeReports(reports []types.Report) (types.Report, types.SpecReports, specCounts, types.SpecReports, RunConfig) {
	merged := reports[0]
	for _, next := range reports[1:] {
		merged = merged.Add(next)
	}
	itSpecs := merged.SpecReports.WithLeafNodeType(types.NodeTypeIt)
	counts := specCounts{
		Total:   len(itSpecs),
		Passed:  itSpecs.CountWithState(types.SpecStatePassed),
		Failed:  itSpecs.CountWithState(types.SpecStateFailureStates),
		Skipped: itSpecs.CountWithState(types.SpecStateSkipped),
		Pending: itSpecs.CountWithState(types.SpecStatePending),
	}
	return merged, itSpecs, counts, extractHooks(merged.SpecReports), extractRunConfig(merged.SpecReports)
}

func extractHooks(reports types.SpecReports) types.SpecReports {
	var hooks types.SpecReports
	for _, sr := range reports {
		if sr.LeafNodeType.Is(types.NodeTypeReportBeforeSuite | types.NodeTypeReportAfterSuite) {
			continue
		}
		if sr.LeafNodeType.Is(types.NodeTypesForSuiteLevelNodes) {
			hooks = append(hooks, sr)
		}
	}
	return hooks
}

func extractRunConfig(reports types.SpecReports) RunConfig {
	var cfg RunConfig
	for _, sr := range reports {
		for _, entry := range sr.ReportEntries {
			if entry.Name != RunConfigEntryName {
				continue
			}
			if entry.Value.AsJSON != "" {
				if err := json.Unmarshal([]byte(entry.Value.AsJSON), &cfg); err == nil {
					return cfg
				}
			}
		}
	}
	return cfg
}

func fallbackStatus(ctx WorkflowContext) string {
	switch ctx.StepOutcome {
	case "skipped":
		return "SKIPPED"
	case "cancelled":
		return "CANCELLED"
	case "failure", "timed_out":
		return "FAILED"
	}
	switch strings.ToLower(ctx.JobStatus) {
	case "cancelled":
		return "CANCELLED"
	case "failure":
		return "FAILED"
	case "skipped":
		return "SKIPPED"
	}
	if ctx.StepOutcome == "success" {
		return "UNKNOWN"
	}
	return "FAILED"
}

func writeMetadataTable(b *strings.Builder, r types.Report, cfg RunConfig, durSec float64, ctx WorkflowContext) {
	var rows [][2]string

	if cfg.HelmEnv != "" || cfg.KubeContext != "" {
		env := ""
		if cfg.HelmEnv != "" {
			env = fmt.Sprintf("`%s`", escapeTableCell(cfg.HelmEnv))
		}
		if cfg.KubeContext != "" {
			if env != "" {
				env += " "
			}
			env += fmt.Sprintf("(context: `%s`)", escapeTableCell(cfg.KubeContext))
		}
		rows = append(rows, [2]string{"Environment", env})
	}

	if cfg.Model != "" || cfg.Variant != "" {
		model := strings.Trim(fmt.Sprintf("%s / %s", cfg.Model, cfg.Variant), " /")
		val := fmt.Sprintf("`%s`", escapeTableCell(model))
		if cfg.ServedName != "" {
			val += fmt.Sprintf(" (servedName: `%s`)", escapeTableCell(cfg.ServedName))
		}
		rows = append(rows, [2]string{"Model", val})
	}

	if cfg.Release != "" || cfg.Namespace != "" || cfg.Backend != "" || cfg.GPUCount > 0 {
		var parts []string
		if cfg.Namespace != "" || cfg.Release != "" {
			rel := strings.Trim(fmt.Sprintf("%s/%s", cfg.Namespace, cfg.Release), "/")
			parts = append(parts, fmt.Sprintf("`%s`", escapeTableCell(rel)))
		}
		if cfg.Backend != "" {
			parts = append(parts, fmt.Sprintf("backend: `%s`", escapeTableCell(cfg.Backend)))
		}
		if cfg.GPUCount > 0 {
			parts = append(parts, fmt.Sprintf("GPUs: `%d`", cfg.GPUCount))
		}
		if len(cfg.GPUProducts) > 0 {
			parts = append(parts, fmt.Sprintf("products: `%s`", escapeTableCell(strings.Join(cfg.GPUProducts, ", "))))
		}
		rows = append(rows, [2]string{"Release", strings.Join(parts, " · ")})
	}

	if cfg.Catalog != "" {
		rows = append(rows, [2]string{"Catalog", fmt.Sprintf("`%s`", escapeTableCell(cfg.Catalog))})
	}

	if cfg.SkipInstall || cfg.KeepInstall {
		var flags []string
		if cfg.SkipInstall {
			flags = append(flags, "`E2E_SKIP_INSTALL=true`")
		}
		if cfg.KeepInstall {
			flags = append(flags, "`KEEP_INSTALL=true`")
		}
		rows = append(rows, [2]string{"Flags", strings.Join(flags, ", ")})
	}

	if !r.StartTime.IsZero() && !r.EndTime.IsZero() {
		rows = append(rows, [2]string{
			"Window",
			fmt.Sprintf("`%s` → `%s` (%s)",
				r.StartTime.UTC().Format(time.RFC3339),
				r.EndTime.UTC().Format(time.RFC3339),
				FormatDuration(durSec),
			),
		})
	}

	if wf := formatWorkflowCell(ctx); wf != "" {
		rows = append(rows, [2]string{"Workflow", wf})
	}

	if len(rows) > 0 {
		b.WriteString("### Run Metadata\n\n")
		writeKeyValueTable(b, rows)
	}
}

func formatWorkflowCell(ctx WorkflowContext) string {
	var parts []string
	if ctx.Ref != "" {
		parts = append(parts, fmt.Sprintf("ref: `%s`", escapeTableCell(ctx.Ref)))
	}
	if ctx.SHA != "" {
		short := ctx.SHA
		if len(short) > 7 {
			short = short[:7]
		}
		parts = append(parts, fmt.Sprintf("sha: `%s`", escapeTableCell(short)))
	}
	if ctx.Event != "" {
		parts = append(parts, fmt.Sprintf("event: `%s`", escapeTableCell(ctx.Event)))
	}
	if ctx.RunURL != "" {
		parts = append(parts, fmt.Sprintf("[View run](%s)", ctx.RunURL))
	}
	return strings.Join(parts, " · ")
}

func writeKeyValueTable(b *strings.Builder, rows [][2]string) {
	b.WriteString("| Field | Value |\n")
	b.WriteString("| --- | --- |\n")
	for _, row := range rows {
		fmt.Fprintf(b, "| %s | %s |\n", escapeTableCell(row[0]), row[1])
	}
	b.WriteString("\n")
}

func writeCountsTable(b *strings.Builder, c specCounts) {
	b.WriteString("### Spec Counts\n\n")
	b.WriteString("| Passed | Failed | Skipped | Pending | Total |\n")
	b.WriteString("| :---: | :---: | :---: | :---: | :---: |\n")
	fmt.Fprintf(b, "| %d | %d | %d | %d | %d |\n\n",
		c.Passed, c.Failed, c.Skipped, c.Pending, c.Total)
}

func writeFailuresSection(b *strings.Builder, specialReasons []string, hooks, specs types.SpecReports) {
	b.WriteString("### Failures\n\n")

	if len(specialReasons) > 0 {
		for _, reason := range specialReasons {
			fmt.Fprintf(b, "- **Suite failure:** %s\n", strings.TrimSpace(reason))
		}
		b.WriteString("\n")
	}

	for _, h := range hooks {
		if h.Failed() || !h.Failure.IsZero() {
			writeSpecFailure(b, h)
		}
	}
	for _, s := range specs {
		if s.Failed() || !s.Failure.IsZero() {
			writeSpecFailure(b, s)
		}
	}
}

func writeSpecFailure(b *strings.Builder, sr types.SpecReport) {
	fmt.Fprintf(b, "#### %s (`%s`, %s)\n\n",
		specName(sr), sr.State.String(), FormatDuration(sr.RunTime.Seconds()))

	if loc := formatCodeLocation(sr.LeafNodeLocation); loc != "" {
		fmt.Fprintf(b, "Location: `%s`\n\n", loc)
	}
	steps := extractSteps(sr)
	if len(steps) > 0 {
		last := steps[len(steps)-1]
		fmt.Fprintf(b, "Last step: `%s`\n\n", last.Name)
	}

	if !sr.Failure.IsZero() {
		if msg := strings.TrimSpace(sr.Failure.Message); msg != "" {
			truncated := truncateMessage(msg, maxFailureChars)
			fence := codeFence(truncated)
			fmt.Fprintf(b, "%stext\n%s\n%s\n\n", fence, truncated, fence)
		}
		if panicText := strings.TrimSpace(sr.Failure.ForwardedPanic); panicText != "" {
			truncated := truncateMessage(panicText, maxFailureChars)
			fence := codeFence(truncated)
			fmt.Fprintf(b, "Panic:\n\n%stext\n%s\n%s\n\n", fence, truncated, fence)
		}
	}

	if len(sr.AdditionalFailures) > 0 {
		fmt.Fprintf(b, "<details>\n<summary>Additional failures (%d)</summary>\n\n", len(sr.AdditionalFailures))
		for _, af := range sr.AdditionalFailures {
			nodeType := sr.LeafNodeType
			if af.Failure.FailureNodeType != types.NodeTypeInvalid {
				nodeType = af.Failure.FailureNodeType
			}
			label := nodeType.String()
			if label == "" {
				label = "Cleanup"
			}
			loc := af.Failure.Location
			if loc == (types.CodeLocation{}) {
				loc = af.Failure.FailureNodeLocation
			}

			fmt.Fprintf(b, "- **%s** (`%s`)", label, af.State.String())
			if formatted := formatCodeLocation(loc); formatted != "" {
				fmt.Fprintf(b, " at `%s`", formatted)
			}
			b.WriteString("\n\n")
			if msg := strings.TrimSpace(af.Failure.Message); msg != "" {
				truncated := truncateMessage(msg, maxFailureChars)
				fence := codeFence(truncated)
				fmt.Fprintf(b, "%stext\n%s\n%s\n\n", fence, truncated, fence)
			}
			if panicText := strings.TrimSpace(af.Failure.ForwardedPanic); panicText != "" {
				truncated := truncateMessage(panicText, maxFailureChars)
				fence := codeFence(truncated)
				fmt.Fprintf(b, "Panic:\n\n%stext\n%s\n%s\n\n", fence, truncated, fence)
			}
		}
		b.WriteString("</details>\n\n")
	}
}

func writeSpecTable(b *strings.Builder, heading, colName string, items types.SpecReports) {
	fmt.Fprintf(b, "%s\n\n", heading)
	fmt.Fprintf(b, "| %s | Status | Duration |\n", colName)
	b.WriteString("| --- | :---: | :---: |\n")
	for _, item := range items {
		fmt.Fprintf(b, "| %s | %s | %s |\n",
			escapeTableCell(specName(item)),
			statusBadge(item.State.String()),
			FormatDuration(item.RunTime.Seconds()),
		)
	}
	b.WriteString("\n")
}

func writeStepTimings(b *strings.Builder, hooks, specs types.SpecReports) {
	type itemWithSteps struct {
		sr    types.SpecReport
		steps []stepTiming
	}
	var withSteps []itemWithSteps
	for _, h := range hooks {
		if steps := extractSteps(h); len(steps) > 0 {
			withSteps = append(withSteps, itemWithSteps{sr: h, steps: steps})
		}
	}
	for _, s := range specs {
		if steps := extractSteps(s); len(steps) > 0 {
			withSteps = append(withSteps, itemWithSteps{sr: s, steps: steps})
		}
	}
	if len(withSteps) == 0 {
		return
	}

	b.WriteString("<details>\n<summary>Step timings</summary>\n\n")
	for _, item := range withSteps {
		fmt.Fprintf(b, "**%s** (%s)\n\n", specName(item.sr), FormatDuration(item.sr.RunTime.Seconds()))
		for _, st := range item.steps {
			fmt.Fprintf(b, "- %s — %s\n", st.Name, FormatDuration(st.DurationSeconds))
		}
		b.WriteString("\n")
	}
	b.WriteString("</details>\n\n")
}

func extractSteps(sr types.SpecReport) []stepTiming {
	var starts []int
	for i, ev := range sr.SpecEvents {
		if ev.SpecEventType == types.SpecEventByStart {
			starts = append(starts, i)
		}
	}
	if len(starts) == 0 {
		return nil
	}

	steps := make([]stepTiming, 0, len(starts))
	for pos, idx := range starts {
		startEv := sr.SpecEvents[idx]
		var dur float64

		// Ginkgo records SpecEventByEnd only when By() receives a callback;
		// bare By("step") calls derive duration from the next step or EndTime.
		for j := idx + 1; j < len(sr.SpecEvents); j++ {
			if pos+1 < len(starts) && j >= starts[pos+1] {
				break
			}
			if sr.SpecEvents[j].SpecEventType == types.SpecEventByEnd && sr.SpecEvents[j].Duration > 0 {
				dur = sr.SpecEvents[j].Duration.Seconds()
				break
			}
		}

		if dur == 0 && !startEv.TimelineLocation.Time.IsZero() {
			end := sr.EndTime
			if pos+1 < len(starts) {
				nextTime := sr.SpecEvents[starts[pos+1]].TimelineLocation.Time
				if !nextTime.IsZero() {
					end = nextTime
				}
			}
			if !end.IsZero() {
				if d := end.Sub(startEv.TimelineLocation.Time).Seconds(); d > 0 {
					dur = d
				}
			}
		}

		if dur < 0 {
			dur = 0
		}
		steps = append(steps, stepTiming{
			Name:            startEv.Message,
			DurationSeconds: dur,
		})
	}
	return steps
}

func specName(sr types.SpecReport) string {
	if name := sr.FullText(); name != "" {
		return name
	}
	return sr.LeafNodeType.String()
}

func formatCodeLocation(cl types.CodeLocation) string {
	if cl.FileName == "" {
		return ""
	}
	file := filepath.ToSlash(cl.FileName)
	const marker = "test/e2e/gpu/"
	if _, after, ok := strings.Cut(file, marker); ok {
		file = marker + after
	} else {
		file = filepath.Base(file)
	}
	if cl.LineNumber > 0 {
		return fmt.Sprintf("%s:%d", file, cl.LineNumber)
	}
	return file
}

func statusBadge(state string) string {
	switch state {
	case "passed":
		return "✅ passed"
	case "failed":
		return "❌ failed"
	case "timedout":
		return "⏱️ timedout"
	case "panicked":
		return "💥 panicked"
	case "aborted":
		return "🛑 aborted"
	case "interrupted":
		return "🛑 interrupted"
	case "skipped":
		return "⏭️ skipped"
	case "pending":
		return "⏸️ pending"
	default:
		return state
	}
}

func anyFailed(items types.SpecReports) bool {
	for _, item := range items {
		if item.Failed() || !item.Failure.IsZero() {
			return true
		}
	}
	return false
}

func escapeTableCell(s string) string {
	s = strings.ReplaceAll(s, "\r\n", " ")
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\r", " ")
	s = strings.ReplaceAll(s, "|", `\|`)
	return strings.TrimSpace(s)
}

func truncateMessage(s string, limit int) string {
	s = strings.TrimSpace(s)
	runes := []rune(s)
	if len(runes) <= limit {
		return s
	}
	const head = 2200
	const tail = 1500
	omitted := len(runes) - head - tail
	return string(runes[:head]) +
		fmt.Sprintf("\n... (truncated %d chars) ...\n", omitted) +
		string(runes[len(runes)-tail:])
}

func codeFence(content string) string {
	fence := "```"
	for strings.Contains(content, fence) {
		fence += "`"
	}
	return fence
}
