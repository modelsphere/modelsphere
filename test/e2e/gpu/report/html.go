package report

import (
	"bytes"
	"fmt"
	"html/template"
	"math"
	"strings"
	"time"

	"github.com/onsi/ginkgo/v2/types"
)

const (
	maxHTMLFailureChars = 32000
	maxHTMLOutputChars  = 64000
)

type htmlReportData struct {
	Title          string
	Suite          string
	StatusLabel    string
	StatusClass    string
	Headline       string
	Warning        string
	FallbackReason string
	Window         string
	Duration       string
	RunURL         string
	ArtifactURL    string
	Ref            string
	ShortSHA       string
	Event          string
	Counts         specCounts
	ShowCounts     bool
	MetaRows       []htmlMetaRow
	SpecialReasons []string
	Failures       []htmlSpec
	Hooks          []htmlSpec
	Specs          []htmlSpec
}

type htmlMetaRow struct {
	Label string
	Value string
}

type htmlSpec struct {
	Name               string
	State              string
	BadgeClass         string
	FilterGroup        string
	Failed             bool
	Duration           string
	BarPct             int
	Location           string
	LastStep           string
	Message            string
	Panic              string
	AdditionalFailures []htmlFailure
	Steps              []htmlStep
	Output             string
}

type htmlStep struct {
	Name     string
	Duration string
	BarPct   int
}

type htmlFailure struct {
	Label    string
	State    string
	Location string
	Message  string
	Panic    string
}

var htmlPageTmpl = template.Must(template.New("report").Parse(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{.Title}}</title>
<style>
:root {
  --bg: #f6f8fa;
  --surface: #ffffff;
  --surface-alt: #f0f3f6;
  --border: #d0d7de;
  --text: #1f2328;
  --muted: #59636e;
  --pass: #1a7f37;
  --pass-bg: #dafbe1;
  --fail: #cf222e;
  --fail-bg: #ffebe9;
  --warn: #9a6700;
  --warn-bg: #fff8c5;
  --skip: #59636e;
  --skip-bg: #eaeef2;
  --accent: #0969da;
  --code-bg: #f6f8fa;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0d1117;
    --surface: #161b22;
    --surface-alt: #1f242c;
    --border: #30363d;
    --text: #e6edf3;
    --muted: #8b949e;
    --pass: #3fb950;
    --pass-bg: rgba(46, 160, 67, 0.15);
    --fail: #f85149;
    --fail-bg: rgba(248, 81, 73, 0.15);
    --warn: #d29922;
    --warn-bg: rgba(187, 128, 9, 0.15);
    --skip: #8b949e;
    --skip-bg: rgba(110, 118, 129, 0.18);
    --accent: #58a6ff;
    --code-bg: #0d1117;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0;
  padding: 24px 16px 48px;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
  background: var(--bg);
  color: var(--text);
  line-height: 1.5;
}
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
code, pre {
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
}
.container { max-width: 1120px; margin: 0 auto; display: grid; gap: 16px; }
.card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 18px 20px;
}
.header { display: flex; flex-wrap: wrap; gap: 12px; align-items: flex-start; justify-content: space-between; }
.header h1 { margin: 6px 0 4px; font-size: 1.35rem; }
.headline { color: var(--muted); font-size: 0.95rem; }
.pill {
  display: inline-block;
  padding: 3px 10px;
  border-radius: 999px;
  font-size: 0.78rem;
  font-weight: 600;
  letter-spacing: 0.02em;
}
.pill.pass { color: var(--pass); background: var(--pass-bg); }
.pill.fail { color: var(--fail); background: var(--fail-bg); }
.pill.warn { color: var(--warn); background: var(--warn-bg); }
.pill.skip { color: var(--skip); background: var(--skip-bg); }
.actions { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; font-size: 0.88rem; }
.btn-link {
  padding: 6px 12px;
  border: 1px solid var(--border);
  border-radius: 6px;
  background: var(--surface-alt);
  color: var(--text);
  font-weight: 500;
}
.banner {
  margin-top: 12px;
  padding: 10px 12px;
  border-radius: 8px;
  border-left: 4px solid var(--warn);
  background: var(--warn-bg);
  font-size: 0.92rem;
}
.kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); gap: 12px; }
.kpi {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 12px 16px;
}
.kpi .label { font-size: 0.8rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.04em; }
.kpi .val { font-size: 1.6rem; font-weight: 700; margin-top: 2px; }
.kpi.pass .val { color: var(--pass); }
.kpi.fail .val { color: var(--fail); }
.meta-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
  gap: 10px 18px;
}
.meta-item .label { font-size: 0.78rem; color: var(--muted); }
.meta-item .val { font-size: 0.9rem; word-break: break-word; }
h2 { margin: 0 0 12px; font-size: 1.05rem; }
.failure-card {
  border: 1px solid var(--border);
  border-left: 4px solid var(--fail);
  border-radius: 8px;
  padding: 14px 16px;
  margin-top: 12px;
  background: var(--surface-alt);
}
.failure-head { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 8px; align-items: center; }
.failure-title { font-weight: 600; }
.meta-line { font-size: 0.84rem; color: var(--muted); margin-top: 4px; }
pre.log {
  margin: 10px 0 0;
  padding: 12px;
  background: var(--code-bg);
  border: 1px solid var(--border);
  border-radius: 6px;
  overflow-x: auto;
  font-size: 0.82rem;
  line-height: 1.45;
  white-space: pre-wrap;
  word-break: break-word;
}
.toolbar { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center; gap: 10px; margin-bottom: 10px; }
.filters { display: flex; gap: 6px; flex-wrap: wrap; }
.filter-btn {
  border: 1px solid var(--border);
  background: var(--surface-alt);
  color: var(--text);
  padding: 4px 10px;
  border-radius: 999px;
  font-size: 0.82rem;
  cursor: pointer;
}
.filter-btn.active {
  background: var(--accent);
  border-color: var(--accent);
  color: #fff;
}
.spec-list { display: grid; gap: 8px; }
.spec-row {
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 10px 14px;
}
.spec-row[hidden] { display: none; }
.spec-top { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; justify-content: space-between; }
.spec-name { font-weight: 500; flex: 1 1 280px; }
.spec-dur { display: flex; align-items: center; gap: 8px; min-width: 150px; justify-content: flex-end; font-size: 0.86rem; color: var(--muted); }
.bar-track { width: 72px; height: 6px; border-radius: 999px; background: var(--surface-alt); overflow: hidden; }
.bar-fill { height: 100%; background: var(--accent); border-radius: 999px; }
.spec-row.fail .bar-fill { background: var(--fail); }
details { margin-top: 8px; }
summary { cursor: pointer; font-size: 0.86rem; color: var(--accent); user-select: none; }
.step-list { list-style: none; padding: 0; margin: 8px 0 0; display: grid; gap: 6px; }
.step-item { display: flex; align-items: center; justify-content: space-between; gap: 12px; font-size: 0.85rem; }
.step-name { flex: 1; }
</style>
</head>
<body>
<div class="container">
  <section class="card">
    <div class="header">
      <div>
        <span class="pill {{.StatusClass}}">{{.StatusLabel}}</span>
        <h1>{{.Title}}</h1>
        <div class="headline">{{.Headline}}</div>
        {{if .Window}}<div class="meta-line">{{.Window}}</div>{{end}}
      </div>
      <div class="actions">
        {{if .Ref}}<span class="pill skip">{{.Ref}}{{if .ShortSHA}} @ {{.ShortSHA}}{{end}}</span>{{end}}
        {{if .Event}}<span class="pill skip">{{.Event}}</span>{{end}}
        {{if .RunURL}}<a class="btn-link" href="{{.RunURL}}">Workflow Run</a>{{end}}
      </div>
    </div>
    {{if .Warning}}<div class="banner">{{.Warning}}</div>{{end}}
    {{if .FallbackReason}}<div class="banner">{{.FallbackReason}}</div>{{end}}
  </section>

  {{if .ShowCounts}}
  <section class="kpis">
    <div class="kpi"><div class="label">Total</div><div class="val">{{.Counts.Total}}</div></div>
    <div class="kpi pass"><div class="label">Passed</div><div class="val">{{.Counts.Passed}}</div></div>
    <div class="kpi {{if gt .Counts.Failed 0}}fail{{end}}"><div class="label">Failed</div><div class="val">{{.Counts.Failed}}</div></div>
    <div class="kpi"><div class="label">Skipped</div><div class="val">{{.Counts.Skipped}}</div></div>
    <div class="kpi"><div class="label">Pending</div><div class="val">{{.Counts.Pending}}</div></div>
  </section>
  {{end}}

  {{if .MetaRows}}
  <section class="card">
    <h2>Run Metadata</h2>
    <div class="meta-grid">
      {{range .MetaRows}}
      <div class="meta-item">
        <div class="label">{{.Label}}</div>
        <div class="val"><code>{{.Value}}</code></div>
      </div>
      {{end}}
    </div>
  </section>
  {{end}}

  {{if or .SpecialReasons .Failures}}
  <section class="card">
    <h2>Failures</h2>
    {{if .SpecialReasons}}
    <ul>
      {{range .SpecialReasons}}<li><strong>Suite failure:</strong> {{.}}</li>{{end}}
    </ul>
    {{end}}
    {{range .Failures}}
    <div class="failure-card">
      <div class="failure-head">
        <span class="failure-title">{{.Name}}</span>
        <span><span class="pill {{.BadgeClass}}">{{.State}}</span> <span class="meta-line">{{.Duration}}</span></span>
      </div>
      {{if .Location}}<div class="meta-line">Location: <code>{{.Location}}</code></div>{{end}}
      {{if .LastStep}}<div class="meta-line">Last step: <code>{{.LastStep}}</code></div>{{end}}
      {{if .Message}}<pre class="log">{{.Message}}</pre>{{end}}
      {{if .Panic}}<div class="meta-line">Panic:</div><pre class="log">{{.Panic}}</pre>{{end}}
      {{if .AdditionalFailures}}
      <details>
        <summary>Additional failures ({{len .AdditionalFailures}})</summary>
        {{range .AdditionalFailures}}
        <div class="meta-line"><strong>{{.Label}}</strong> (<code>{{.State}}</code>){{if .Location}} at <code>{{.Location}}</code>{{end}}</div>
        {{if .Message}}<pre class="log">{{.Message}}</pre>{{end}}
        {{if .Panic}}<pre class="log">{{.Panic}}</pre>{{end}}
        {{end}}
      </details>
      {{end}}
      {{if .Output}}
      <details>
        <summary>GinkgoWriter output</summary>
        <pre class="log">{{.Output}}</pre>
      </details>
      {{end}}
    </div>
    {{end}}
  </section>
  {{end}}

  {{if .Hooks}}
  <section class="card">
    <h2>Suite Lifecycle</h2>
    <div class="spec-list">
      {{range .Hooks}}
      <div class="spec-row {{.BadgeClass}}">
        <div class="spec-top">
          <span class="pill {{.BadgeClass}}">{{.State}}</span>
          <span class="spec-name">{{.Name}}</span>
          <span class="spec-dur">
            <span>{{.Duration}}</span>
            <span class="bar-track"><span class="bar-fill" style="width: {{.BarPct}}%"></span></span>
          </span>
        </div>
        {{if .Location}}<div class="meta-line"><code>{{.Location}}</code></div>{{end}}
        {{if .Steps}}
        <details>
          <summary>Steps ({{len .Steps}})</summary>
          <ul class="step-list">
            {{range .Steps}}
            <li class="step-item">
              <span class="step-name">{{.Name}}</span>
              <span class="spec-dur"><span>{{.Duration}}</span><span class="bar-track"><span class="bar-fill" style="width: {{.BarPct}}%"></span></span></span>
            </li>
            {{end}}
          </ul>
        </details>
        {{end}}
        {{if .Output}}
        <details>
          <summary>GinkgoWriter output</summary>
          <pre class="log">{{.Output}}</pre>
        </details>
        {{end}}
      </div>
      {{end}}
    </div>
  </section>
  {{end}}

  {{if .Specs}}
  <section class="card">
    <div class="toolbar">
      <h2 style="margin: 0;">Specs ({{len .Specs}})</h2>
      <div class="filters" role="group" aria-label="Filter specs">
        <button type="button" class="filter-btn active" data-filter="all">All</button>
        <button type="button" class="filter-btn" data-filter="failed">Failed</button>
        <button type="button" class="filter-btn" data-filter="passed">Passed</button>
        <button type="button" class="filter-btn" data-filter="skipped">Skipped</button>
      </div>
    </div>
    <div class="spec-list" id="spec-list">
      {{range .Specs}}
      <div class="spec-row {{.BadgeClass}}" data-filter-group="{{.FilterGroup}}">
        <div class="spec-top">
          <span class="pill {{.BadgeClass}}">{{.State}}</span>
          <span class="spec-name">{{.Name}}</span>
          <span class="spec-dur">
            <span>{{.Duration}}</span>
            <span class="bar-track"><span class="bar-fill" style="width: {{.BarPct}}%"></span></span>
          </span>
        </div>
        {{if .Location}}<div class="meta-line"><code>{{.Location}}</code></div>{{end}}
        {{if .Steps}}
        <details>
          <summary>Steps ({{len .Steps}})</summary>
          <ul class="step-list">
            {{range .Steps}}
            <li class="step-item">
              <span class="step-name">{{.Name}}</span>
              <span class="spec-dur"><span>{{.Duration}}</span><span class="bar-track"><span class="bar-fill" style="width: {{.BarPct}}%"></span></span></span>
            </li>
            {{end}}
          </ul>
        </details>
        {{end}}
        {{if .Output}}
        <details>
          <summary>GinkgoWriter output</summary>
          <pre class="log">{{.Output}}</pre>
        </details>
        {{end}}
      </div>
      {{end}}
    </div>
  </section>
  {{end}}
</div>
<script>
(function () {
  var buttons = document.querySelectorAll('.filter-btn');
  var rows = document.querySelectorAll('#spec-list .spec-row');
  buttons.forEach(function (btn) {
    btn.addEventListener('click', function () {
      var filter = btn.getAttribute('data-filter');
      buttons.forEach(function (b) { b.classList.toggle('active', b === btn); });
      rows.forEach(function (row) {
        row.hidden = filter !== 'all' && row.getAttribute('data-filter-group') !== filter;
      });
    });
  });
})();
</script>
</body>
</html>
`))

// RenderHTML renders Ginkgo JSON reports and workflow metadata into a standalone HTML page.
func RenderHTML(reports []types.Report, ctx WorkflowContext) (string, error) {
	if len(reports) == 0 {
		return RenderFallbackHTML(ctx, "Ginkgo JSON report contained no suite reports.")
	}

	merged, itSpecs, counts, hooks, runCfg := analyzeReports(reports)
	passed := merged.SuiteSucceeded && (ctx.StepOutcome == "" || ctx.StepOutcome == "success")

	statusLabel, statusClass := "PASSED", "pass"
	if !passed {
		statusLabel, statusClass = "FAILED", "fail"
	}

	durSec := merged.RunTime.Seconds()
	dur := FormatDuration(durSec)
	var headline string
	switch {
	case counts.Failed > 0:
		headline = fmt.Sprintf("%d/%d specs failed (%d passed) · %s", counts.Failed, counts.Total, counts.Passed, dur)
	case !merged.SuiteSucceeded:
		headline = fmt.Sprintf("Suite failed outside spec assertions (%d/%d specs passed) · %s", counts.Passed, counts.Total, dur)
	case !passed:
		headline = fmt.Sprintf("%d/%d specs passed, but e2e step outcome was %s · %s", counts.Passed, counts.Total, ctx.StepOutcome, dur)
	default:
		headline = fmt.Sprintf("%d/%d specs passed · %s", counts.Passed, counts.Total, dur)
	}

	var warning string
	if merged.SuiteSucceeded && ctx.StepOutcome != "" && ctx.StepOutcome != "success" {
		warning = fmt.Sprintf("The Ginkgo suite reported success, but the e2e workflow step ended with outcome %q.", ctx.StepOutcome)
	}

	var window string
	if !merged.StartTime.IsZero() && !merged.EndTime.IsZero() {
		window = fmt.Sprintf("%s → %s (%s)",
			merged.StartTime.UTC().Format(time.RFC3339),
			merged.EndTime.UTC().Format(time.RFC3339),
			dur,
		)
	}

	hookViews := buildHTMLSpecs(hooks)
	specViews := buildHTMLSpecs(itSpecs)

	var failures []htmlSpec
	for _, h := range hookViews {
		if h.Failed {
			failures = append(failures, h)
		}
	}
	for _, s := range specViews {
		if s.Failed {
			failures = append(failures, s)
		}
	}

	title := "GPU E2E Report: " + statusLabel
	if merged.SuiteDescription != "" {
		title = fmt.Sprintf("%s — %s", merged.SuiteDescription, statusLabel)
	}

	data := htmlReportData{
		Title:          title,
		Suite:          merged.SuiteDescription,
		StatusLabel:    statusLabel,
		StatusClass:    statusClass,
		Headline:       headline,
		Warning:        warning,
		Window:         window,
		Duration:       dur,
		RunURL:         ctx.RunURL,
		ArtifactURL:    ctx.ArtifactURL,
		Ref:            ctx.Ref,
		ShortSHA:       shortSHA(ctx.SHA),
		Event:          ctx.Event,
		Counts:         counts,
		ShowCounts:     true,
		MetaRows:       buildHTMLMetaRows(runCfg, ctx),
		SpecialReasons: merged.SpecialSuiteFailureReasons,
		Failures:       failures,
		Hooks:          hookViews,
		Specs:          specViews,
	}

	return execHTMLTemplate(data)
}

// RenderFallbackHTML renders a standalone HTML page when no Ginkgo JSON report could be loaded.
func RenderFallbackHTML(ctx WorkflowContext, reason string) (string, error) {
	status := fallbackStatus(ctx)
	statusClass := "fail"
	switch status {
	case "SKIPPED", "CANCELLED":
		statusClass = "skip"
	case "UNKNOWN":
		statusClass = "warn"
	}

	var rows []htmlMetaRow
	if ctx.JobStatus != "" {
		rows = append(rows, htmlMetaRow{Label: "Job Status", Value: ctx.JobStatus})
	}
	if ctx.StepOutcome != "" {
		rows = append(rows, htmlMetaRow{Label: "E2E Step Outcome", Value: ctx.StepOutcome})
	}

	data := htmlReportData{
		Title:          "GPU E2E Report: " + status,
		StatusLabel:    status,
		StatusClass:    statusClass,
		Headline:       "No Ginkgo JSON suite report was available.",
		FallbackReason: strings.TrimSpace(reason),
		RunURL:         ctx.RunURL,
		ArtifactURL:    ctx.ArtifactURL,
		Ref:            ctx.Ref,
		ShortSHA:       shortSHA(ctx.SHA),
		Event:          ctx.Event,
		MetaRows:       rows,
	}

	return execHTMLTemplate(data)
}

func execHTMLTemplate(data htmlReportData) (string, error) {
	var buf bytes.Buffer
	if err := htmlPageTmpl.Execute(&buf, data); err != nil {
		return "", fmt.Errorf("render html report: %w", err)
	}
	return buf.String(), nil
}

func buildHTMLMetaRows(cfg RunConfig, ctx WorkflowContext) []htmlMetaRow {
	var rows []htmlMetaRow

	if cfg.HelmEnv != "" || cfg.KubeContext != "" {
		val := cfg.HelmEnv
		if cfg.KubeContext != "" {
			if val != "" {
				val += " "
			}
			val += fmt.Sprintf("(context: %s)", cfg.KubeContext)
		}
		rows = append(rows, htmlMetaRow{Label: "Environment", Value: val})
	}

	if cfg.Model != "" || cfg.Variant != "" {
		model := strings.Trim(fmt.Sprintf("%s / %s", cfg.Model, cfg.Variant), " /")
		if cfg.ServedName != "" {
			model += fmt.Sprintf(" (servedName: %s)", cfg.ServedName)
		}
		rows = append(rows, htmlMetaRow{Label: "Model", Value: model})
	}

	if cfg.Release != "" || cfg.Namespace != "" || cfg.Backend != "" || cfg.GPUCount > 0 {
		var parts []string
		if cfg.Namespace != "" || cfg.Release != "" {
			parts = append(parts, strings.Trim(fmt.Sprintf("%s/%s", cfg.Namespace, cfg.Release), "/"))
		}
		if cfg.Backend != "" {
			parts = append(parts, "backend: "+cfg.Backend)
		}
		if cfg.GPUCount > 0 {
			parts = append(parts, fmt.Sprintf("GPUs: %d", cfg.GPUCount))
		}
		if len(cfg.GPUProducts) > 0 {
			parts = append(parts, "products: "+strings.Join(cfg.GPUProducts, ", "))
		}
		rows = append(rows, htmlMetaRow{Label: "Release", Value: strings.Join(parts, " · ")})
	}

	if cfg.Catalog != "" {
		rows = append(rows, htmlMetaRow{Label: "Catalog", Value: cfg.Catalog})
	}

	if cfg.SkipInstall || cfg.KeepInstall {
		var flags []string
		if cfg.SkipInstall {
			flags = append(flags, "E2E_SKIP_INSTALL=true")
		}
		if cfg.KeepInstall {
			flags = append(flags, "KEEP_INSTALL=true")
		}
		rows = append(rows, htmlMetaRow{Label: "Flags", Value: strings.Join(flags, ", ")})
	}

	if ctx.JobStatus != "" {
		rows = append(rows, htmlMetaRow{Label: "Job Status", Value: ctx.JobStatus})
	}
	if ctx.StepOutcome != "" {
		rows = append(rows, htmlMetaRow{Label: "E2E Step Outcome", Value: ctx.StepOutcome})
	}

	return rows
}

func buildHTMLSpecs(items types.SpecReports) []htmlSpec {
	if len(items) == 0 {
		return nil
	}
	var maxSec float64
	for _, sr := range items {
		if s := sr.RunTime.Seconds(); s > maxSec {
			maxSec = s
		}
	}

	out := make([]htmlSpec, 0, len(items))
	for _, sr := range items {
		specSec := sr.RunTime.Seconds()
		steps := extractSteps(sr)
		htmlSteps := make([]htmlStep, 0, len(steps))
		for _, st := range steps {
			htmlSteps = append(htmlSteps, htmlStep{
				Name:     st.Name,
				Duration: FormatDuration(st.DurationSeconds),
				BarPct:   barPercent(st.DurationSeconds, specSec),
			})
		}

		var lastStep string
		if len(steps) > 0 {
			lastStep = steps[len(steps)-1].Name
		}

		var msg, panicText string
		if !sr.Failure.IsZero() {
			if m := strings.TrimSpace(sr.Failure.Message); m != "" {
				msg = truncateMessage(m, maxHTMLFailureChars)
			}
			if p := strings.TrimSpace(sr.Failure.ForwardedPanic); p != "" {
				panicText = truncateMessage(p, maxHTMLFailureChars)
			}
		}

		var addFailures []htmlFailure
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
			var afMsg, afPanic string
			if m := strings.TrimSpace(af.Failure.Message); m != "" {
				afMsg = truncateMessage(m, maxHTMLFailureChars)
			}
			if p := strings.TrimSpace(af.Failure.ForwardedPanic); p != "" {
				afPanic = truncateMessage(p, maxHTMLFailureChars)
			}
			addFailures = append(addFailures, htmlFailure{
				Label:    label,
				State:    af.State.String(),
				Location: formatCodeLocation(loc),
				Message:  afMsg,
				Panic:    afPanic,
			})
		}

		failed := sr.Failed() || !sr.Failure.IsZero()
		out = append(out, htmlSpec{
			Name:               specName(sr),
			State:              sr.State.String(),
			BadgeClass:         htmlBadgeClass(sr.State),
			FilterGroup:        htmlFilterGroup(sr.State),
			Failed:             failed,
			Duration:           FormatDuration(specSec),
			BarPct:             barPercent(specSec, maxSec),
			Location:           formatCodeLocation(sr.LeafNodeLocation),
			LastStep:           lastStep,
			Message:            msg,
			Panic:              panicText,
			AdditionalFailures: addFailures,
			Steps:              htmlSteps,
			Output:             tailMessage(sr.CombinedOutput(), maxHTMLOutputChars),
		})
	}
	return out
}

func htmlBadgeClass(st types.SpecState) string {
	switch {
	case st.Is(types.SpecStatePassed):
		return "pass"
	case st.Is(types.SpecStateFailureStates):
		return "fail"
	case st.Is(types.SpecStatePending):
		return "warn"
	default:
		return "skip"
	}
}

func htmlFilterGroup(st types.SpecState) string {
	switch {
	case st.Is(types.SpecStatePassed):
		return "passed"
	case st.Is(types.SpecStateFailureStates):
		return "failed"
	default:
		return "skipped"
	}
}

func barPercent(part, total float64) int {
	if part <= 0 || total <= 0 {
		return 0
	}
	pct := int(math.Round((part / total) * 100))
	if pct < 2 {
		return 2
	}
	if pct > 100 {
		return 100
	}
	return pct
}

func shortSHA(sha string) string {
	if len(sha) > 7 {
		return sha[:7]
	}
	return sha
}

func tailMessage(s string, limit int) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	runes := []rune(s)
	if len(runes) <= limit {
		return s
	}
	omitted := len(runes) - limit
	return fmt.Sprintf("... (truncated %d leading chars) ...\n", omitted) + string(runes[len(runes)-limit:])
}
