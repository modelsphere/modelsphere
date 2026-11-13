# Contributing

## Where a change belongs

This repository installs ModelSphere; it is not where most of it lives. A change
to how the router picks a backend, how the scaler decides, or what the engine
charts render belongs in that component's own repository under
[github.com/modelsphere](https://github.com/modelsphere) — the
[Components table](README.md#components) says which is which. What belongs here:
the Ansible playbooks, the kubeadm path, the helmfile and its environments, the
offline bundle, and the documentation for all of it.

## Before you open a pull request

Run what the change touches:

| Changed | Run |
|---|---|
| anything under `helmfile.yaml.gotmpl`, `environments/`, or a release's values | `helmfile -e default build` — it must render. `helmfile -e default write-values` shows what a release actually receives, which is the thing to check when a value moves |
| a playbook or a role | `ansible-playbook --syntax-check`, and `ansible -i inventory.ini.example --list-hosts all` if you touched the inventory contract |
| `script/*.sh` | `bash -n`, and the script's own test if it has one (`script/test_node_prep_rdma.sh` is the pattern: a fake sysfs tree, no hardware) |
| documentation | check that every relative link still resolves, including `#anchors` — moving a section breaks links pointing into it, silently |

A change that cannot be checked by any of these is worth saying so in the pull
request, along with how you did convince yourself it works.

## Two things that make a change easy to review

**Say why, not what.** The diff says what changed. The message and the pull
request should say what was wrong with the old behaviour, and how you know the
new one is right — the command you ran, the output you got. "Measured on a
3-node cluster: before X, after Y" is worth more than any amount of description.

**A check that cannot fail is not a check.** If you add one — a test, a guard, a
validation — make it fail on the broken input as well as pass on the good one,
and say in the pull request that you saw both. Several bugs in this repository
were checks that reported success on a tree they were not actually reading.

Commit messages and code comments are in English: the repository is public, and
a comment nobody can read is a comment nobody maintains.

## License

By contributing you agree that your contribution is licensed under the
[Apache License 2.0](LICENSE), the same as the rest of the repository.
