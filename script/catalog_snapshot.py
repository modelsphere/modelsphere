#!/usr/bin/env python3
"""Pack the model catalog and the engine charts for catalog-mirror's snapshot.

swissd deploys a model from two things it reads over HTTP: the model catalog and
the chart the catalog names (sglang or vllm). An offline cluster reaches
neither, so the bundle carries a copy and catalog-mirror serves it in the
cluster (its `snapshot`, see the chart's README). This writes that copy: a gzip'd
tar with the two trees nginx serves.

  model-catalog/  index.json and every version file it names (schema v1),
                  index-v2.json, every variant file and history it names (v2).
                  Not the HTML reports: swiss does not read them, and they are
                  most of the catalog's size -- the snapshot travels in a ConfigMap,
                  which holds 1 MiB.
  helm-charts/    the newest release of every chart the catalog names, plus any
                  version passed with --pin, and an index.yaml naming the
                  archives by bare file name so helm fetches them from the mirror.

Every version and variant file is checked against the digest its index pins
(histories have none and are copied as published), and every chart
constraint in the catalog has to be met by an archive in the snapshot -- a snapshot that
cannot deploy some model fails here, not in the room with no network.

  catalog_snapshot.py <out.tar.gz> [--pin sglang=0.8.2 ...] [--charts-dir DIR]
                  [--models a,b --images-out FILE]

--charts-dir also writes the chart archives there (the bundle's charts/, where
the images a model's chart pins inside itself are read from). --models names
catalog models whose engine images go to --images-out, one address per line,
exactly as the catalog spells them: `model` for every variant's, or
`model:variant` for that one variant's.
Environment: CATALOG_URL, CHARTS_URL (defaults: the public GitHub Pages sites).
"""
import argparse, hashlib, io, json, os, re, sys, tarfile, time, urllib.error, urllib.request

import yaml

CATALOG_URL = os.environ.get("CATALOG_URL", "https://modelsphere.github.io/model-catalog/").rstrip("/") + "/"
CHARTS_URL = os.environ.get("CHARTS_URL", "https://modelsphere.github.io/helm-charts/").rstrip("/") + "/"
LIMIT = 1024 * 1024  # a ConfigMap's size limit, which the snapshot has to fit


def get(url, tries=4):
    # A snapshot is a few hundred small fetches, so a single stalled read used
    # to fail the whole bundle. Measured from an Ascend build host: three bundle
    # attempts in a row each died on one `read operation timed out`, while the
    # same files came back in 0.3 s a minute later. Retry each fetch instead.
    req = urllib.request.Request(url, headers={"User-Agent": "modelsphere-offline-bundle"})
    for i in range(tries):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code < 500 or i == tries - 1:
                raise
        except (urllib.error.URLError, OSError):
            if i == tries - 1:
                raise
        print(f"    retrying {url} ({i + 1}/{tries - 1})", file=sys.stderr)
        time.sleep(5 * (i + 1))


def sha(b):
    return hashlib.sha256(b).hexdigest()


def safe_rel(rel):
    p = os.path.normpath(rel)
    if os.path.isabs(rel) or p.startswith(".."):
        raise SystemExit(f"catalog path {rel!r} escapes the catalog")
    return p


def pinned(rel, want):
    data = get(CATALOG_URL + rel)
    want = (want or "").partition(":")[2]
    if not want or sha(data) != want:
        raise SystemExit(f"{rel}: sha256 {sha(data)[:16]} does not match the index ({want[:16] or 'no digest'})")
    return data


def vkey(v):
    """A release version's sort key; None for a pre-release, which is never picked."""
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", str(v).strip())
    return tuple(int(x) for x in m.groups()) if m else None


def bound(v):
    """The x.y.z of a lone lower bound, a pre-release one included (0.8.0-rc1).
    The whole string has to be that: `0.8.0 <1.0` is a range this script does
    not read, and taking its prefix would drop the upper bound."""
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-[0-9A-Za-z.-]+)?", str(v).strip())
    return tuple(int(x) for x in m.groups()) if m else None


def satisfies(version, constraint):
    """True/False for the spellings the catalog uses -- an exact version,
    `>=x.y.z`, or none at all (any release) -- and None for anything else."""
    c = str(constraint or "").strip()
    if c and c == str(version).strip():
        return True                                  # an exact version, pre-releases included
    if not c:
        return vkey(version) is not None
    if c.startswith(">="):
        b = bound(c[2:])
        return None if b is None else (vkey(version) is not None and vkey(version) >= b)
    if vkey(c):
        return version == c
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--pin", action="append", default=[], help="name=version, also bundled")
    ap.add_argument("--charts-dir")
    ap.add_argument("--models", default="")
    ap.add_argument("--images-out")
    a = ap.parse_args()

    files = {}  # path in the archive -> bytes
    constraints = []  # (chart, constraint, where, schema)

    # v1: index.json and its version files.
    raw = get(CATALOG_URL + "index.json")
    files["model-catalog/index.json"] = raw
    for m in json.loads(raw).get("models", []):
        for v in m.get("versions", []):
            rel = safe_rel(v["path"])
            data = pinned(rel, v.get("digest"))
            files[f"model-catalog/{rel}"] = data
            doc = yaml.safe_load(data) or {}
            for var in (doc.get("variants") or {}).values() if isinstance(doc.get("variants"), dict) else doc.get("variants") or []:
                ch = (var or {}).get("chart") or {}
                if ch.get("name"):
                    constraints.append((ch["name"], ch.get("version", ""), rel, "v1"))

    # v2: index-v2.json, each variant's current file and its history.
    picks = [p.strip() for p in a.models.split(",") if p.strip()]
    want_variants = {p for p in picks if ":" in p}   # model:variant
    found = set()
    images = {}  # address -> the models naming it
    raw = get(CATALOG_URL + "index-v2.json")
    files["model-catalog/index-v2.json"] = raw
    for m in json.loads(raw).get("models", []):
        for v in m.get("variants", []):
            rel = safe_rel(v["path"])
            data = pinned(rel, v.get("digest"))
            files[f"model-catalog/{rel}"] = data
            doc = yaml.safe_load(data) or {}
            img = doc.get("image") or {}
            whole = m["name"] in picks
            one = f'{m["name"]}:{v["id"]}' in want_variants
            if (whole or one) and img.get("repository") and img.get("tag"):
                images.setdefault(f'{img["repository"]}:{img["tag"]}', set()).add(f'{m["name"]}:{v["id"]}')
                if whole:
                    found.add(m["name"])
                if one:
                    found.add(f'{m["name"]}:{v["id"]}')
            ch = doc.get("chart") or {}
            if ch.get("name"):
                constraints.append((ch["name"], ch.get("version", ""), rel, "v2"))
            if v.get("history"):
                h = safe_rel(v["history"])
                files[f"model-catalog/{h}"] = get(CATALOG_URL + h)

    missing = set(picks) - found
    if missing:
        raise SystemExit(f"--models: not in the v2 catalog, or naming no image: {', '.join(sorted(missing))}")
    if a.images_out:
        with open(a.images_out, "w") as f:
            f.write("".join(i + "\n" for i in sorted(images)))
        for i, ms in sorted(images.items()):
            print(f"    engine image {i} ({', '.join(sorted(ms))})")

    # Charts: the newest release of every chart named, plus the pins, plus --
    # for a v2 entry the newest one does not meet (an exact older version, an
    # exact pre-release) -- the release swissd would pick for it: the newest
    # that meets the constraint.
    index = yaml.safe_load(get(CHARTS_URL + "index.yaml"))["entries"]
    want = {}
    for name in sorted({c[0] for c in constraints}):
        if name not in index:
            raise SystemExit(f"the catalog names chart {name!r}, which {CHARTS_URL} does not publish")
        releases = [e for e in index[name] if vkey(e["version"])]
        if not releases:
            raise SystemExit(f"{CHARTS_URL} publishes only pre-releases of {name}; --pin one to bundle it")
        newest = max(releases, key=lambda e: vkey(e["version"]))
        want[(name, newest["version"])] = newest
    for name, c, _w, s in constraints:
        if s != "v2" or name not in index or any(satisfies(v, c) for n, v in want if n == name):
            continue
        fits = [e for e in index[name] if satisfies(e["version"], c)]
        if fits:
            best = max(fits, key=lambda e: vkey(e["version"]) or bound(e["version"]) or ())
            want[(name, best["version"])] = best
    for p in a.pin:
        name, _, ver = p.partition("=")
        e = next((e for e in index.get(name, []) if e["version"] == ver), None)
        if e is None:
            raise SystemExit(f"--pin {p}: {CHARTS_URL} has no such release")
        want[(name, ver)] = e

    out_entries = {}
    for (name, ver), e in sorted(want.items()):
        url = e["urls"][0]
        data = get(url if "://" in url else CHARTS_URL + url)
        if sha(data) != e.get("digest"):
            raise SystemExit(f"{name}-{ver}.tgz: sha256 does not match the index")
        fname = f"{name}-{ver}.tgz"
        files[f"helm-charts/{fname}"] = data
        if a.charts_dir:
            with open(os.path.join(a.charts_dir, fname), "wb") as f:
                f.write(data)
        out_entries.setdefault(name, []).append(dict(e, urls=[fname]))
    files["helm-charts/index.yaml"] = yaml.safe_dump(
        {"apiVersion": "v1", "entries": out_entries}, sort_keys=False).encode()

    have = {}
    for name, ver in want:
        have.setdefault(name, []).append(ver)
    # Only v2 has to be deployable: it is what the offline site profile points
    # swiss at. v1 rides along because catalog-mirror's readiness and its
    # `helm test` read index.json, and its oldest files pin exact chart versions
    # nobody needs offline -- so those are reported, not refused.
    unmet = []
    for n, c, w, s in constraints:
        verdicts = [satisfies(v, c) for v in have.get(n, [])]
        if any(verdicts):
            continue
        why = (f"chart constraint {c!r} is not a spelling this script reads (exact or >=x.y.z)"
               if None in verdicts else f"no {n} chart in the snapshot meets {c!r}")
        unmet.append((n, c, w, s))
        print(f"    {'' if s == 'v2' else '(v1, not used offline) '}{why}: {w}", file=sys.stderr)
    if any(s == "v2" for *_, s in unmet):
        raise SystemExit("a v2 catalog entry would find no chart offline; --pin a version that meets it")

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        for rel in sorted(files):
            info = tarfile.TarInfo(rel)
            info.size, info.mode, info.mtime = len(files[rel]), 0o644, 0
            t.addfile(info, io.BytesIO(files[rel]))
    data = buf.getvalue()
    if len(data) > LIMIT:
        raise SystemExit(f"the snapshot is {len(data)} bytes, over the {LIMIT} a ConfigMap holds")
    with open(a.out, "wb") as f:
        f.write(data)
    n_cat = sum(k.startswith("model-catalog/") for k in files)
    print(f"    catalog snapshot: {n_cat} catalog files, charts "
          + ", ".join(f"{n}-{v}" for n, v in sorted(want)) + f"; {len(data)} bytes")


if __name__ == "__main__":
    main()
