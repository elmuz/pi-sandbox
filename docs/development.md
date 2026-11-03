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
├── examples/mcp.json              project-level Pi MCP client example
├── examples/mcp/catafalco/        optional target config templates
├── scripts/isolation-test.sh      static and live isolation checks
├── scripts/mcp-selftest.sh        contract checks without an MCP stack
├── install.sh                     creates state dirs and symlinks the launcher
├── LICENSE                        MIT license
└── README.md
```

Lint rules live in `.hadolint.yaml`, `.yamllint.yml` and
`.markdownlint-cli2.yaml`.

## CI

`.github/workflows/ci.yml` runs on pushes to `main` and on pull requests:

- ShellCheck on the launcher, installer, scripts and entrypoint;
- the MCP contract self-test, which does not need an MCP stack;
- the static isolation self-test, which also runs the Python policy tests;
- Hadolint on both Dockerfiles;
- yamllint on the Compose file, examples and workflow;
- markdownlint on Markdown files;
- actionlint on the workflow itself;
- a Docker build of `image/pi.Dockerfile`, followed by a `pi --version`
  smoke test;
- a Docker build of `image/egress-proxy.Dockerfile`, followed by a policy
  validation smoke test.

## Tests

The MCP contract self-test needs no MCP stack:

```bash
scripts/mcp-selftest.sh
```

It checks token validation, fail-closed behaviour for opted-in projects, the
absence of a token in the podman argv, and idempotent creation of the internal
control network.

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
