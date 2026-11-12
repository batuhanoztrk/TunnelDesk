#!/usr/bin/python3
"""Create update metadata; signing is a separate Keychain-backed Sparkle step."""
import argparse
import base64
import datetime
import email.utils
import html
import pathlib
import plistlib
import re
import xml.etree.ElementTree as ET
import zipfile

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPO = "https://github.com/batuhanoztrk/TunnelDesk"
ET.register_namespace("sparkle", SPARKLE)


def generate(archive, signature, notes):
    match = re.fullmatch(r"TunnelDesk-(\d+\.\d+\.\d+)-macOS-(arm64|x86_64)\.zip", archive.name)
    if not match:
        raise ValueError("Unexpected archive name")
    version, arch = match.groups()
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Invalid Ed25519 signature")
    with zipfile.ZipFile(archive) as bundle:
        info = plistlib.loads(bundle.read("TunnelDesk.app/Contents/Info.plist"))
    if info.get("CFBundleIdentifier") != "tr.tunneldesk.mac" or info.get("CFBundleShortVersionString") != version:
        raise ValueError("Archive identifier/version does not match release")
    build = str(info["CFBundleVersion"])
    if not build.isdecimal() or int(build) < 1:
        raise ValueError("Build number must be a positive integer")
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "TunnelDesk"
    ET.SubElement(channel, "link").text = REPO
    ET.SubElement(channel, "language").text = "tr"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "TunnelDesk " + version
    ET.SubElement(item, "link").text = REPO + "/releases/tag/v" + version
    ET.SubElement(item, "pubDate").text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
    ET.SubElement(item, "description").text = "<pre>" + html.escape(notes) + "</pre>"
    ET.SubElement(item, "{" + SPARKLE + "}version").text = build
    ET.SubElement(item, "{" + SPARKLE + "}shortVersionString").text = version
    ET.SubElement(item, "{" + SPARKLE + "}minimumSystemVersion").text = info.get("LSMinimumSystemVersion", "14.0")
    if arch == "arm64":
        ET.SubElement(item, "{" + SPARKLE + "}hardwareRequirements").text = "arm64"
    ET.SubElement(item, "enclosure", {
        "url": REPO + "/releases/download/v" + version + "/" + archive.name,
        "length": str(archive.stat().st_size),
        "type": "application/octet-stream",
        "{" + SPARKLE + "}edSignature": signature,
    })
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=pathlib.Path, required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--notes", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    notes = args.notes.read_text(encoding="utf-8") if args.notes else "TunnelDesk güncellemesi."
    args.output.write_bytes(generate(args.archive, args.signature, notes))
