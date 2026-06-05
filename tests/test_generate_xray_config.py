import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "08-generate-xray-config.py"


def load_module():
    spec = importlib.util.spec_from_file_location("generate_xray_config", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class OutputLinksTests(unittest.TestCase):
    def test_output_links_prints_each_tag_and_file_path(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            links_dir = root / "links"
            links_out = root / "all-links.txt"
            public_key = root / "reality-public.key"
            short_id = root / "reality-short-id.txt"
            public_key.write_text("PUBLIC_KEY\n", encoding="utf-8")
            short_id.write_text("abcd\n", encoding="utf-8")
            env = {
                "LINKS_DIR": str(links_dir),
                "LINKS_OUT": str(links_out),
                "REALITY_PUBLIC_KEY_PATH": str(public_key),
                "REALITY_SHORT_ID_PATH": str(short_id),
                "SERVER_DOMAIN": "landing.example.com",
                "SERVER_IP_IPV4": "",
                "SERVER_IP_IPV6": "",
                "SERVER_ALIAS": "landing-vps",
                "CLIENT_FINGERPRINT": "chrome",
            }
            clients = [
                {
                    "tag": "relay-new",
                    "uuid": "11111111-1111-1111-1111-111111111111",
                    "listen_port": 51043,
                    "server_name": "www.microsoft.com",
                    "flow": "xtls-rprx-vision",
                }
            ]

            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                module.output_links(env, clients)

            output = stdout.getvalue()
            self.assertIn(f"relay-new -> {links_dir / 'relay-new.txt'}", output)
            self.assertTrue((links_dir / "relay-new.txt").exists())


if __name__ == "__main__":
    unittest.main()
