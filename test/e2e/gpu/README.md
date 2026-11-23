# Real-environment GPU e2e tests moved

The complete GPU suite, reporting tools and `e2e-gpu` GitHub workflow now live
in **[modelsphere/modelsphere-e2e](https://github.com/modelsphere/modelsphere-e2e)**.
Use that repository's setup guide and `make test-e2e-gpu` entrypoint.

This repository retains the deployment Helmfile, shared environments/templates
and provisioning commands. The destination suite fetches this repository at run
time: latest `main` by default, or an optional branch, tag, or full commit SHA.
The [kind e2e suite](../kind/README.md) and its workflow remain here.

Cutover order: merge the destination migration first, then this removal. Keep
the destination's `E2E_GPU_ENABLED` variable unset/false until this workflow
removal is merged and old queued/running GPU jobs have drained; only then enable
the destination. Cross-repository concurrency groups do not protect the cluster.
