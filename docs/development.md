# Development

## Repository layout

```text
pi-sandbox/
├── .github/workflows/ci.yml       lint and image build
├── assets/pi-sandbox.jpg          project logo
├── bin/pi-sandbox                 interactive launcher
├── docs/                          detailed documentation
├── image/
│   ├── pi.Dockerfile              Pi image definition
│   ├── entrypoint.sh              seeds config and per-session auth
│   ├── egress-proxy.Dockerfile    proxy image definition
│   ├── egress_proxy.py            policy-enforcing HTTP(S) proxy
│   ├── tests/test_egress_proxy.py policy parser and decision tests
│   ├── sandbox-status.ts          container-only footer marker
│   └── .dockerignore
├── compose/compose.yaml           optional MCP Compose scaffold
├── examples/config.example        launcher config template
├── examples/egress-policy.example.conf
├── examples/mcp.json              sandbox project MCP config example
├── examples/mcp/target/           optional target config templates
├── .githooks/pre-push             runs the linters before every push
├── scripts/isolation-test.sh      static and live isolation checks
├── scripts/lint.sh                shared lint entrypoint for CI and local use
├── scripts/mcp-auth-test.sh       Pi header-expansion contract check
├── scripts/mcp-selftest.sh        contract checks without an MCP stack
├── scripts/workspace-test.sh      disposable workspace fake-Podman checks
├── install.sh                     creates state dirs and symlinks the launcher
├── LICENSE                        MIT license
└── README.md
```

Lint rules live in `.hadolint.yaml`, `.yamllint.yml` and
`.markdownlint-cli2.yaml`.

## CI

`.github/workflows/ci.yml` runs on pushes to `main` and on pull requests.
The lint job only calls `scripts/lint.sh --with-tests`, which performs:

- ShellCheck on the launcher, installer, scripts and entrypoint;
- the MCP contract self-test, which does not need an MCP stack;
- the disposable workspace self-test, which uses fake Podman and writes only
  to a temporary copy;
- the static isolation self-test, which also runs the Python policy tests;
- Hadolint on both Dockerfiles;
- yamllint on the Compose file, examples and workflow;
- markdownlint on Markdown files;
- actionlint on the workflow itself.

The `build` and `proxy` jobs then build `image/pi.Dockerfile` and
`image/egress-proxy.Dockerfile`, followed by a `pi --version` smoke test and
a policy validation smoke test.

## Local checks

CI and local development share one entrypoint, with pinned tool versions:

```bash
scripts/lint.sh --with-tests
```

The pins are ShellCheck 0.11.0, Hadolint 2.15.1, yamllint 1.38.0,
markdownlint-cli2 0.24.0 and actionlint 1.7.12. A tool is taken from `PATH`
only when its version matches the pin exactly; otherwise the same version
runs from a container image through podman or docker. Running this script
before a push therefore reproduces the CI lint job instead of approximating
it: a version skew cannot hide a finding that CI would report, and the
reverse is equally true.

Enable the pre-push hook so the checks run automatically:

```bash
git config core.hooksPath .githooks
```

A push can still bypass it when needed:

```bash
PI_SANDBOX_SKIP_LINT=1 git push
```

## Tests

The MCP contract self-test needs no MCP stack:

```bash
scripts/mcp-selftest.sh
```

It checks token validation, fail-closed behaviour for opted-in projects, the
absence of a token in the podman argv, idempotent creation of the internal
control network, and the Pi header-expansion contract. The header check starts
a fake MCP endpoint and is skipped when `pi` or `python3` is unavailable.

The disposable workspace self-test needs no container runtime:

```bash
scripts/workspace-test.sh
```

It proves that an ephemeral launch writes to a launcher-owned copy, that the
host checkout is untouched, that the copy is parked or discarded as requested,
and that `rw` still mounts the host checkout.

The isolation self-test has two modes:

```bash
scripts/isolation-test.sh
scripts/isolation-test.sh --live
```

Static mode checks launcher flags, auth seeding, resource limits, default-off
GPG and the policy parser. Live mode creates temporary networks and a temporary
proxy, then checks that public HTTPS works through the proxy while direct
public, direct private and proxied private connections fail.

The policy tests can also be run directly:

```bash
python3 -m unittest discover -s image/tests -p 'test_*.py'
```

The full image smoke tests are:

```bash
docker build -t localhost/pi-sandbox:ci image
docker run --rm localhost/pi-sandbox:ci pi --version

docker build \
  -f image/egress-proxy.Dockerfile \
  -t localhost/pi-sandbox-egress:ci \
  image
policy="$PWD/examples/egress-policy.example.conf"
docker run --rm \
  --mount "type=bind,src=$policy,dst=/etc/pi-egress/policy.conf,ro" \
  localhost/pi-sandbox-egress:ci \
  --check-policy --policy /etc/pi-egress/policy.conf
```

## Upgrading the pinned Pi version

Image tags follow the host `pi --version`, but the launcher fallback and the
documentation carry an explicit pin. After upgrading Pi on the host:

1. Note the new version: `pi --version`.
2. Update the fallback in `bin/pi-sandbox`
   (`${host_pi_version:-X.Y.Z}`).
3. Update `ARG PI_VERSION=X.Y.Z` in `image/pi.Dockerfile`.
4. Update the version references in `docs/getting-started.md`: the fallback
   sentence, the example image tag and the `PI_VERSION=` update example.
5. Rebuild both images: `pi-sandbox --update`.
6. Verify: `podman run --rm localhost/pi-sandbox:X.Y.Z pi --version`.

Old image tags are left in local storage; remove them with
`podman image prune` or `podman rmi` when convenient. A running sandbox keeps
the image it started with, so restart it to pick up the new version. Sessions,
auth and configuration under `~/.local/share/pi-sandbox` survive the rebuild.

## Rebuilding on hosts without overlayfs

`podman build` mounts the build context through overlayfs. On a kernel with no
overlayfs module, the build fails before the first step with:

```text
mount overlay: ... userxattr: no such device
```

Point the rootless overlay driver at `fuse-overlayfs` in
`~/.config/containers/storage.conf`:

```toml
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
```

The `[storage.options.overlay]` section matters; a `mount_program` under
`[storage.options]` does not fix the build-context mount. Container storage
already falls back to `fuse-overlayfs` on such hosts, so only the build path
needs the explicit setting. After the change, `pi-sandbox --update` builds both
images normally.
