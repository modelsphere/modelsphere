package report

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/onsi/ginkgo/v2/types"
)

// RunConfigEntryName is the Ginkgo ReportEntry key holding non-secret run metadata.
const RunConfigEntryName = "run-config"

// RunConfig records non-secret configuration for the e2e run inside Ginkgo's JSON report.
type RunConfig struct {
	HelmEnv     string   `json:"helmEnv,omitempty"`
	KubeContext string   `json:"kubeContext,omitempty"`
	Model       string   `json:"model,omitempty"`
	Variant     string   `json:"variant,omitempty"`
	ServedName  string   `json:"servedName,omitempty"`
	Release     string   `json:"release,omitempty"`
	Namespace   string   `json:"namespace,omitempty"`
	Backend     string   `json:"backend,omitempty"`
	Catalog     string   `json:"catalog,omitempty"`
	GPUCount    int      `json:"gpuCount,omitempty"`
	GPUProducts []string `json:"gpuProducts,omitempty"`
	SkipInstall bool     `json:"skipInstall,omitempty"`
	KeepInstall bool     `json:"keepInstall,omitempty"`
}

// WorkflowContext carries GitHub Actions metadata into Markdown and HTML rendering.
type WorkflowContext struct {
	StepOutcome       string
	JobStatus         string
	RunURL            string
	ArtifactURL       string
	ReportURL         string
	ReportUploadError string
	Ref               string
	SHA               string
	Event             string
}

// ReadJSON loads Ginkgo's -ginkgo.json-report array ([]types.Report) from path.
func ReadJSON(path string) ([]types.Report, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var reports []types.Report
	if err := json.Unmarshal(data, &reports); err != nil {
		return nil, fmt.Errorf("parse ginkgo json report %s: %w", path, err)
	}
	return reports, nil
}
