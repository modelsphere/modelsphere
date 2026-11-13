# Console: opening the portal

ModelSphere Console is the web UI for the stack: users, roles and login, plus
the Model Serving pages backed by swissd, which the helmfile installs as its
own release beside it. The portal is on by default (`enabled.console` in
`environments/default.yaml`).

## First visit

The Service is a `NodePort`, so the UI is reachable as soon as the release is
up — no ingress needed:

```bash
NODE_PORT=$(kubectl -n console get svc console-console -o jsonpath='{.spec.ports[0].nodePort}')
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "http://$NODE_IP:$NODE_PORT/"
```

(That is the chart's own address recipe; `helm status console -n console` prints
it too. Behind a firewall, `kubectl -n console port-forward svc/console-console
8080:8080` and open `http://localhost:8080/` instead.)

Sign in as `admin` with the password `P@88w0rd`. The first login asks you to
set a new password — do it; the default is public knowledge. (If your cluster
renamed the namespace, use `namespaces.console` from your environment file in
place of `console` above.)

## What you get

- **Identity**: users, roles, login records — the admin you just set a password
  for, and any further users you create.
- **Model Serving pages**: deploying a model (`docs/deploy-a-model.md`) lights
  them up — console talks to the `swissd` release over the cluster DNS, no
  extra wiring.

swissd runs without persistent storage by default: its sqlite database sits on
an emptyDir, so the audit log and plan history are lost whenever the pod is
deleted or rescheduled, a rollout included. Turning on storage for swiss is
recommended — `persistence.enabled: true` in
`console/swiss-overrides.yaml.gotmpl`, which needs a default StorageClass or
`persistence.storageClass` / `persistence.existingClaim`. An install that
already has the `swissd-data` PVC sets `persistence.enabled: true` there
before upgrading, or first runs `kubectl -n <console-ns> annotate pvc
swissd-data helm.sh/resource-policy=keep`; otherwise helm deletes the claim.

## Swiss running elsewhere

If your swissd lives outside this helmfile, the bundled `swissd` release is
the wrong one to keep: turn the portal off (`enabled.console: false`) and set
`swiss.enabled: false` plus `externalSwiss` (url, proxyKey secret, profile) for
a console release of your own — the console chart's
`values-existing-stack.example.yaml` shows the shape.
