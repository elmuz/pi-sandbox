import importlib.util
import ipaddress
import socket
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "egress_proxy.py"
SPEC = importlib.util.spec_from_file_location("egress_proxy", SCRIPT)
assert SPEC and SPEC.loader
egress_proxy = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = egress_proxy
SPEC.loader.exec_module(egress_proxy)

Policy = egress_proxy.Policy
PolicyError = egress_proxy.PolicyError
ResolvedAddress = egress_proxy.ResolvedAddress
Rule = egress_proxy.Rule
load_rules = egress_proxy.load_rules
parse_rule = egress_proxy.parse_rule


def resolved(address, port=0):
    ip = ipaddress.ip_address(address)
    if ip.version == 4:
        return ResolvedAddress(socket.AF_INET, (str(ip), port), ip)
    return ResolvedAddress(socket.AF_INET6, (str(ip), port, 0, 0), ip)


class Resolver:
    def __init__(self, mapping):
        self.mapping = mapping

    def __call__(self, host, port):
        value = self.mapping.get(host)
        if value is None:
            raise OSError("not found")
        if isinstance(value, str):
            value = [value]
        return tuple(resolved(item, port) for item in value)


def make_policy(lines, mapping=None):
    with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as handle:
        handle.write("\n".join(lines))
        path = Path(handle.name)
    try:
        return Policy(load_rules(path), resolver=Resolver(mapping or {}))
    finally:
        path.unlink()


class PolicyTests(unittest.TestCase):
    def test_public_address_is_allowed_by_default(self):
        policy = make_policy([])
        decision = policy.check("93.184.216.34", 443)
        self.assertTrue(decision.allowed)
        self.assertIn("public", decision.reason)

    def test_private_and_link_local_ranges_are_denied(self):
        policy = make_policy([])
        for address in (
            "10.0.0.1",
            "127.0.0.1",
            "169.254.1.1",
            "172.16.0.1",
            "192.168.178.3",
            "::1",
            "fc00::1",
            "fe80::1",
        ):
            with self.subTest(address=address):
                decision = policy.check(address, 80)
                self.assertFalse(decision.allowed)
                self.assertIn("non-public", decision.reason)

    def test_explicit_deny_hostname_and_subdomain(self):
        policy = make_policy(
            ["deny catafalco.example.com"],
            {"catafalco.example.com": "203.0.113.10"},
        )
        self.assertFalse(policy.check("catafalco.example.com", 22).allowed)
        self.assertFalse(policy.check("api.catafalco.example.com", 22).allowed)

    def test_explicit_deny_ip_and_cidr(self):
        policy = make_policy(["deny 203.0.113.10", "deny 198.51.100.0/24"])
        self.assertFalse(policy.check("203.0.113.10", 443).allowed)
        self.assertFalse(policy.check("198.51.100.7", 443).allowed)
        self.assertTrue(policy.check("93.184.216.34", 443).allowed)

    def test_explicit_deny_port_is_specific(self):
        policy = make_policy(
            ["deny catafalco.example.com 22"],
            {"catafalco.example.com": "93.184.216.34"},
        )
        self.assertFalse(policy.check("catafalco.example.com", 22).allowed)
        self.assertTrue(policy.check("catafalco.example.com", 443).allowed)

    def test_allow_private_target_overrides_baseline(self):
        policy = make_policy(["allow 192.168.178.50"])
        self.assertTrue(policy.check("192.168.178.50", 8080).allowed)
        self.assertFalse(policy.check("192.168.178.51", 8080).allowed)

    def test_allow_private_target_port_is_specific(self):
        policy = make_policy(["allow 192.168.178.50 443"])
        self.assertTrue(policy.check("192.168.178.50", 443).allowed)
        self.assertFalse(policy.check("192.168.178.50", 22).allowed)

    def test_allow_private_hostname(self):
        policy = make_policy(
            ["allow docs.internal"],
            {"docs.internal": "192.168.178.60"},
        )
        self.assertTrue(policy.check("docs.internal", 80).allowed)
        self.assertFalse(policy.check("192.168.178.61", 80).allowed)

    def test_deny_wins_over_allow(self):
        policy = make_policy(
            ["allow 192.168.178.0/24", "deny 192.168.178.3"],
        )
        self.assertTrue(policy.check("192.168.178.50", 22).allowed)
        self.assertFalse(policy.check("192.168.178.3", 22).allowed)

    def test_hostname_deny_is_resolved_for_ip_literals(self):
        policy = make_policy(
            ["deny catafalco.example.com"],
            {"catafalco.example.com": "203.0.113.10"},
        )
        self.assertFalse(policy.check("203.0.113.10", 22).allowed)

    def test_hostname_allow_is_resolved_for_ip_literals(self):
        policy = make_policy(
            ["allow docs.internal"],
            {"docs.internal": "192.168.178.60"},
        )
        self.assertTrue(policy.check("192.168.178.60", 80).allowed)

    def test_any_denied_address_denies_the_name(self):
        policy = make_policy(
            [],
            {"mixed.example.com": ["93.184.216.34", "192.168.178.3"]},
        )
        self.assertFalse(policy.check("mixed.example.com", 443).allowed)

    def test_dns_failure_fails_closed(self):
        policy = make_policy([])
        self.assertFalse(policy.check("missing.example.com", 443).allowed)

    def test_policy_file_comments_and_blank_lines(self):
        rules = load_rules_from_text(
            """
            # comment
            deny 203.0.113.10
            allow 192.168.178.0/24 443 # inline comment
            """
        )
        self.assertEqual([rule.action for rule in rules], ["deny", "allow"])
        self.assertEqual(rules[1].port, 443)

    def test_ipv6_inline_port(self):
        rule = parse_rule("deny [2001:db8::1]:443", 1)
        self.assertIsNotNone(rule)
        assert rule is not None
        self.assertEqual(rule.port, 443)
        self.assertEqual(rule.network, ipaddress.ip_network("2001:db8::1/128"))

    def test_invalid_policy_fails(self):
        with self.assertRaises(PolicyError):
            parse_rule("allow", 1)
        with self.assertRaises(PolicyError):
            parse_rule("allow host 99999", 1)
        with self.assertRaises(PolicyError):
            parse_rule("block host", 1)


def load_rules_from_text(text):
    with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as handle:
        handle.write(text)
        path = Path(handle.name)
    try:
        return load_rules(path)
    finally:
        path.unlink()


if __name__ == "__main__":
    unittest.main()
