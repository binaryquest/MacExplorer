#!/usr/bin/env python3
"""Prepare release state and publish verified artifacts before changing the live feed."""
import argparse
import base64
import hashlib
import json
import os
import subprocess
from pathlib import Path
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

from config import BASE_URL, PREFIX, ROOT, app_info, validate_version
from storage import R2

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def sha256(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def previous_release(store, directory, pending_manifest=None):
    path = directory / 'previous-latest.json'
    if not store.get(PREFIX + '/stable/latest.json', path):
        if store.head(PREFIX + '/stable/appcast.xml'):
            raise ValueError('Published feed exists without latest.json; inspect release state before proceeding')
        return None
    previous = json.loads(path.read_text())
    validate_version(previous['version'], previous['build'])
    if not store.get(PREFIX + '/stable/appcast.xml', directory / 'previous-appcast.xml') and previous != pending_manifest:
        raise ValueError('Published metadata exists without its update feed')
    return previous


def prepare(store, directory):
    directory.mkdir(parents=True, exist_ok=True)
    info = app_info()
    prior = previous_release(store, directory)
    validate_version(info['CFBundleShortVersionString'], info['CFBundleVersion'], prior)
    print('Release version and build number validated against R2')


def validate_artifacts(directory):
    manifest = json.loads((directory / 'latest.json').read_text())
    validate_version(manifest['version'], manifest['build'])
    name = f"MacExplorer-{manifest['version']}.dmg"
    expected_url = f"{BASE_URL}/releases/{manifest['version']}/{name}"
    if manifest['url'] != expected_url:
        raise ValueError('Unexpected download URL')
    dmg = directory / name
    if sha256(dmg) != manifest['sha256'] or dmg.stat().st_size != manifest['size']:
        raise ValueError('Installer checksum or length does not match release metadata')
    feed = ET.parse(directory / 'appcast.xml')
    items = [item for item in feed.findall('./channel/item') if item.findtext(SPARKLE + 'version') == str(manifest['build'])]
    if len(items) != 1:
        raise ValueError('Update feed must contain exactly one entry for this build')
    enclosure = items[0].find('enclosure')
    if enclosure is None or enclosure.get('url') != expected_url or enclosure.get('length') != str(manifest['size']):
        raise ValueError('Update enclosure does not match the installer')
    if len(base64.b64decode(enclosure.get(SPARKLE + 'edSignature', ''), validate=True)) != 64:
        raise ValueError('Missing update archive signature')
    # generate_appcast creates the cryptographic feed signature; never rewrite its XML afterward.
    if b'<!-- sparkle-signatures:' not in (directory / 'appcast.xml').read_bytes():
        raise ValueError('Missing signed-feed marker')
    return manifest


def verify_download(url, expected_digest):
    with urllib.request.urlopen(url, timeout=120) as response:
        digest = hashlib.sha256()
        while chunk := response.read(1024 * 1024):
            digest.update(chunk)
    if digest.hexdigest() != expected_digest:
        raise ValueError('Public download differs from the uploaded artifact: ' + url)


def publish(store, directory, verify=verify_download):
    manifest = validate_artifacts(directory)
    with tempfile.TemporaryDirectory(prefix='explorer-release-state-') as temporary:
        previous = previous_release(store, Path(temporary), pending_manifest=manifest)
        # Resume an interrupted pointer update using exactly the same verified artifacts.
        if previous != manifest:
            validate_version(manifest['version'], manifest['build'], previous)
    version = manifest['version']
    names = [f'MacExplorer-{version}.dmg', f'MacExplorer-{version}.md', 'checksums.txt', 'appcast.xml', 'latest.json']
    types = ['application/x-apple-diskimage', 'text/markdown; charset=utf-8', 'text/plain; charset=utf-8', 'application/xml', 'application/json']
    # Preflight every immutable object before writing anything.
    for name in names:
        path = directory / name
        digest = sha256(path)
        old = store.head(f'{PREFIX}/releases/{version}/{name}')
        if old and (old.get('Metadata', {}).get('sha256') != digest or old.get('ContentLength') != path.stat().st_size):
            raise ValueError('Refusing to replace an existing release artifact: ' + name)
    for name, content_type in zip(names, types):
        path = directory / name
        digest = sha256(path)
        store.put(f'{PREFIX}/releases/{version}/{name}', path, content_type, digest, immutable=True)
        verify(f'{BASE_URL}/releases/{version}/{name}', digest)
    # Stable pointers are changed only after all public downloads pass verification.
    store.put(PREFIX + '/stable/latest.json', directory / 'latest.json', 'application/json', sha256(directory / 'latest.json'))
    store.put(PREFIX + '/stable/appcast.xml', directory / 'appcast.xml', 'application/xml', sha256(directory / 'appcast.xml'))
    print(f'Published Explorer {version}; stable update feed updated last')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['prepare', 'publish', 'validate'])
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    if args.action == 'validate':
        validate_artifacts(args.directory)
    elif args.action == 'prepare':
        prepare(R2(), args.directory)
    else:
        subprocess.run(['swift', '-module-cache-path', str(ROOT / '.build/module-cache'),
                        str(ROOT / 'scripts/verify-update.swift'), str(args.directory),
                        str(ROOT / 'Support/Info.plist')], check=True)
        publish(R2(), args.directory)
