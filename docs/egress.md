# Egress

The sandbox has no direct route to the internet or the LAN. A shared proxy
container is the only member with a public network. The sandbox joins an
internal network and sends HTTP(S) traffic to the proxy.

## Network model

```text
sandbox (pi) ── only ──> pi-egress (internal, no NAT)
                             │
                             └── pi-egress-proxy
                                   ├── pi-egress (internal)
                                   └── pi-egress-uplink (public bridge)
```

- `pi-egress` is an internal Podman bridge with no external route.
- `pi-egress-proxy` is dual-homed and is the only container with internet
  access.
- `pi-egress-uplink` is the proxy's normal bridge.
- The sandbox gets `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, their lowercase
  variants, and `NO_PROXY`.
- MCP stays on `pi-control`; it is not routed through the proxy.

The proxy denies every destination by default, including public ones. It always
blocks addresses that are not globally routable, including RFC1918, loopback,
link-local, CGNAT and IPv6 ULA/link-local ranges, unless a rule explicitly
allows them. You must add narrow allow rules for the model provider and any
package or git endpoints the agent needs.

## What the proxy cannot do

Only proxy-aware tools get internet access. `curl`, `git` over HTTPS, most
package managers and Pi provider traffic honour the proxy variables. Raw
sockets, SSH and tools that ignore `HTTP(S)_PROXY` have no internet. That is
the trade-off for not using a root-owned host firewall.

The proxy resolves names on its public side, so the sandbox does not need
external DNS. Tools that resolve names for a direct, non-proxied connection
will fail.

## Peer sessions

The proxy policy controls destinations reached through the proxy. It does not
control traffic between containers on the same bridge. All sandboxes share
`pi-egress`, so one session can connect to another session's container address
and listening ports. The shared bridge is not a boundary between sessions; see
[Security](security.md#concurrent-sessions) for the operational guidance.

## Policy file

The policy is host-owned and mounted read-only into the proxy:

```text
~/.config/pi-sandbox/egress-policy.conf
```

Override it with `PI_SANDBOX_EGRESS_POLICY`. The file is never read from the
workspace, because the agent can write there.

Syntax, one rule per line:

```text
default deny                        # default when omitted
default allow                       # legacy public-by-default
deny  <hostname|IP|CIDR> [port]
allow <hostname|IP|CIDR> [port]
```

- `#` starts a comment.
- A rule without a port matches every port.
- Hostname rules also match subdomains.
- For IPv6 use `[2001:db8::1]:443`, or put the port in a separate field.
- Explicit deny wins over explicit allow.
- An entry may combine hostnames, fixed IPs, CIDRs and dynamic DNS names.

Precedence for each destination:

1. explicit deny;
2. explicit allow;
3. non-public baseline block;
4. default action: deny, unless `default allow` is set.

Example secure policy:

```text
default deny

# Model provider endpoint. Add only the one you use.
allow openrouter.ai 443
# allow api.openai.com 443
# allow api.anthropic.com 443

# Package managers and git hosts, if the agent needs them.
allow registry.npmjs.org 443
allow pypi.org 443
allow files.pythonhosted.org 443
allow github.com 443

# Keep a self-hosted LAN resource reachable.
allow docs.internal
allow 192.168.1.50
allow 192.168.1.0/24 443
```

For a personal threat model that accepts public-by-default, use
`default allow` and keep deny rules for targets the sandbox must not reach
directly:

```text
default allow
deny mcp.example.com
deny 203.0.113.10
deny 203.0.113.0/24
```

Policy files are loaded when the proxy starts. After editing the policy, run
`pi-sandbox --restart-egress` to apply it.

When a request uses an IP literal, the proxy also resolves name-based rules to
check that the literal is not the denied target. For dynamic DNS, name rules are
re-resolved with a short cache, and every resolved address is checked before a
connection is made.

Proxy decisions are logged:

```bash
podman logs pi-egress-proxy
```

Each line includes the verdict, host, port, resolved address and reason.

## Lifecycle

The proxy is one shared helper container, not one per sandbox. It has no
session data and survives sandbox exits so the next launch has internet
immediately. Networks and the proxy container are host-level objects; Podman
does not remove them when a sandbox exits.

```bash
pi-sandbox --egress-status        # show network, proxy and policy state
pi-sandbox --start-egress         # create networks and start the proxy
pi-sandbox --restart-egress       # recreate the proxy with the current image
pi-sandbox --stop-egress          # remove the proxy container
pi-sandbox --check-egress-policy  # validate the policy file
```

`--update` rebuilds both the Pi image and the proxy image, and removes the old
proxy container so the next launch recreates it.

## Migration from public-by-default egress

Egress now denies every destination unless a rule allows it. An existing policy
file with no `default` directive becomes deny-by-default. Add the narrow allow
rules you need, or add `default allow` to keep the previous behaviour for your
personal threat model.

The proxy loads both its image and the policy at container start. After
upgrading, rebuild the images and recreate the proxy:

```bash
pi-sandbox --update
# or, once the new proxy image exists:
pi-sandbox --restart-egress
```

## Migration from a public pi-egress

Older versions created `pi-egress` as a normal bridge. The launcher refuses to
use it if it is not internal. Stop any sandbox containers attached to it, remove
the network once, and let the next launch recreate it:

```bash
podman ps -a --filter network=pi-egress
podman network rm pi-egress
pi-sandbox --start-egress
```

## Configuration

Launcher settings live in:

```text
~/.config/pi-sandbox/config
```

The file is sourced before defaults. Useful values:

```text
PI_SANDBOX_GPG_SIGN=1
PI_SANDBOX_CPUS=2
PI_SANDBOX_NOFILE=8192
PI_SANDBOX_EGRESS_POLICY=/home/user/.config/pi-sandbox/egress-policy.conf
PI_SANDBOX_NO_PROXY=localhost,127.0.0.1,::1,pi-control,mcp-remote,mcp-disk
```

`install.sh` creates the config and policy files only if they do not exist.

## Verification

Run the static checks:

```bash
scripts/isolation-test.sh
```

Run the live checks. They create temporary networks and a temporary proxy, so
they do not disturb a real sandbox:

```bash
scripts/isolation-test.sh --live
```

The live test proves that public HTTPS works through the proxy while direct
public, direct private and proxied private connections fail.
