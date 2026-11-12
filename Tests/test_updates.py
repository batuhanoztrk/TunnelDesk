import base64
import importlib.util
import os
import pathlib
import plistlib
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("appcast", ROOT / "scripts/make-appcast.py")
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="TunnelDesk-update-tests-")
        self.directory = pathlib.Path(self.temp.name)
        self.archive = self.directory / "TunnelDesk-1.2.3-macOS-arm64.zip"
        self.info = {"CFBundleIdentifier": "tr.tunneldesk.mac", "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42", "LSMinimumSystemVersion": "14.0"}
        self.write_archive()
        self.signer = pathlib.Path(os.environ["TUNNELDESK_SPARKLE_DIR"]) / "bin/sign_update"
        self.key = self.directory / "fixture-key"
        # An ephemeral random Ed25519 seed, never a production or Keychain key.
        fd = os.open(self.key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(base64.b64encode(os.urandom(32)))

    def tearDown(self):
        self.temp.cleanup()

    def write_archive(self):
        with zipfile.ZipFile(self.archive, "w") as z:
            z.writestr("TunnelDesk.app/Contents/Info.plist", plistlib.dumps(self.info))

    def tool(self, *args):
        return subprocess.run([str(self.signer), "--ed-key-file", str(self.key), *map(str, args)], capture_output=True, text=True)

    def test_signed_archive_verifies_and_tampering_fails(self):
        signed = self.tool("-p", self.archive)
        self.assertEqual(signed.returncode, 0)
        signature = signed.stdout.strip()
        self.assertEqual(self.tool("--verify", self.archive, signature).returncode, 0)
        with self.archive.open("ab") as f:
            f.write(b"tampered")
        self.assertNotEqual(self.tool("--verify", self.archive, signature).returncode, 0)

    def test_feed_is_signed_and_metadata_tampering_fails(self):
        signature = self.tool("-p", self.archive).stdout.strip()
        feed = self.directory / "appcast.xml"
        feed.write_bytes(appcast.generate(self.archive, signature, "Update notes"))
        self.assertEqual(self.tool(feed).returncode, 0)
        self.assertEqual(self.tool("--verify", feed).returncode, 0)
        feed.write_bytes(feed.read_bytes().replace(b"1.2.3", b"9.9.9"))
        self.assertNotEqual(self.tool("--verify", feed).returncode, 0)

    def test_feed_targets_exact_release_and_preserves_build(self):
        signature = base64.b64encode(bytes(64)).decode()
        xml = ET.fromstring(appcast.generate(self.archive, signature, "<script>plain text</script>"))
        item = xml.find("channel/item")
        self.assertEqual(item.find("{" + appcast.SPARKLE + "}version").text, "42")
        self.assertEqual(item.find("{" + appcast.SPARKLE + "}shortVersionString").text, "1.2.3")
        self.assertEqual(item.find("enclosure").get("url"), "https://github.com/batuhanoztrk/TunnelDesk/releases/download/v1.2.3/TunnelDesk-1.2.3-macOS-arm64.zip")
        self.assertEqual(int(item.find("enclosure").get("length")), self.archive.stat().st_size)
        self.assertNotIn("<script>", item.find("description").text)

    def test_mismatched_bundle_version_is_rejected(self):
        self.info["CFBundleShortVersionString"] = "0.0.1"
        self.write_archive()
        with self.assertRaises(ValueError):
            appcast.generate(self.archive, base64.b64encode(bytes(64)).decode(), "")

    def test_malformed_signature_is_rejected(self):
        with self.assertRaises(ValueError):
            appcast.generate(self.archive, "not-a-signature", "")

    def test_shipping_app_requires_signed_https_updates_without_telemetry(self):
        info = plistlib.loads((ROOT / "Info.plist").read_bytes())
        self.assertEqual(info["SUFeedURL"], "https://github.com/batuhanoztrk/TunnelDesk/releases/latest/download/appcast.xml")
        self.assertEqual(len(base64.b64decode(info["SUPublicEDKey"], validate=True)), 32)
        self.assertTrue(info["SUEnableAutomaticChecks"])
        self.assertTrue(info["SUAutomaticallyUpdate"])
        self.assertTrue(info["SURequireSignedFeed"])
        self.assertTrue(info["SUVerifyUpdateBeforeExtraction"])
        self.assertEqual(info["SUSignedFeedFailureExpirationInterval"], 0)
        self.assertFalse(info["SUEnableSystemProfiling"])
        self.assertTrue(info["LSUIElement"])


if __name__ == "__main__":
    unittest.main()
