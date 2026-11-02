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
│   ├── entrypoint.sh              copies global config, links shared auth
│   ├── sandbox-status.ts          container-only footer marker
│   └── .dockerignore
├── compose/compose.yaml           optional MCP Compose scaffold
├── examples/mcp.json              project-level Pi MCP client example
├── examples/mcp/catafalco/        optional target config templates
├── scripts/mcp-selftest.sh        contract checks without an MCP stack
├── install.sh                     creates state dirs and symlinks the launcher
└── README.md
```

Lint rules live in `.hadolint.yaml`, `.yamllint.yml` and
`.markdownlint-cli2.yaml`.

## CI

`.github/workflows/ci.yml` runs on pushes to `main` and on pull requests:

- ShellCheck on the launcher, installer, self-test and entrypoint;
- the MCP contract self-test, which does not need an MCP stack;
- Hadolint on `image/pi.Dockerfile`;
- yamllint on the Compose file, examples and workflow;
- markdownlint on Markdown files;
- actionlint on the workflow itself;
- a Docker build of `image/pi.Dockerfile`, followed by a `pi --version`
  smoke test.

## Tests

The MCP contract self-test needs no MCP stack:

```bash
scripts/mcp-selftest.sh
```

It checks token validation, fail-closed behaviour for opted-in projects, the
absence of a token in the podman argv, and idempotent creation of the internal
control network.

The full image smoke test is:

```bash
docker build -t localhost/pi-sandbox:ci image
docker run --rm localhost/pi-sandbox:ci pi --version
```
