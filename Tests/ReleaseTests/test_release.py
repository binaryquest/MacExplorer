import base64
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts/release'))
from config import BASE_URL, PREFIX, validate_version, app_info
from publish import publish, validate_artifacts, prepare
from storage import R2


class FakeR2:
    def __init__(self):
        self.objects = {}
        self.calls = []
    def get(self, key, path):
        if key not in self.objects: return False
        path.write_bytes(self.objects[key][0])
        return True
    def head(self, key):
        if key not in self.objects: return None
        data, digest = self.objects[key]
        return {'ContentLength': len(data), 'Metadata': {'sha256': digest}}
    def put(self, key, path, content_type, digest, immutable=False):
        self.calls.append(key)
        self.objects[key] = (path.read_bytes(), digest)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.store = FakeR2()
        self.dmg = self.directory / 'MacExplorer-0.11.0.dmg'
        self.dmg.write_bytes(b'fixture installer')
        manifest = {'version': '0.11.0', 'build': 25, 'url': BASE_URL + '/releases/0.11.0/' + self.dmg.name,
                    'sha256': hashlib.sha256(self.dmg.read_bytes()).hexdigest(), 'size': self.dmg.stat().st_size}
        (self.directory / 'latest.json').write_text(json.dumps(manifest))
        (self.directory / 'MacExplorer-0.11.0.md').write_text('Release notes')
        (self.directory / 'checksums.txt').write_text('Fixture only')
        signature = base64.b64encode(bytes(64)).decode()
        (self.directory / 'appcast.xml').write_text(f'''<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>25</sparkle:version><enclosure url="{manifest['url']}" length="{manifest['size']}" sparkle:edSignature="{signature}"/></item></channel></rss><!-- sparkle-signatures: fixture -->''')

    def test_public_files_are_verified_before_feed_changes(self):
        verified = []
        def verify(url, digest):
            self.assertNotIn(PREFIX + '/stable/appcast.xml', self.store.calls)
            verified.append(url)
        publish(self.store, self.directory, verify)
        self.assertEqual(len(verified), 5)
        self.assertEqual(self.store.calls[-1], PREFIX + '/stable/appcast.xml')

    def test_bad_download_leaves_stable_feed_untouched(self):
        def failed(url, digest): raise ValueError('Cloudflare returned a challenge')
        with self.assertRaises(ValueError): publish(self.store, self.directory, failed)
        self.assertFalse(any('/stable/' in key for key in self.store.calls))

    def test_changed_installer_is_rejected_before_upload(self):
        self.dmg.write_bytes(b'tampered installer')
        with self.assertRaises(ValueError): publish(self.store, self.directory, lambda *_: None)
        self.assertEqual(self.store.calls, [])

    def test_interrupted_first_publication_can_resume_from_identical_artifacts(self):
        path = self.directory / 'latest.json'
        self.store.objects[PREFIX + '/stable/latest.json'] = (path.read_bytes(), 'hash')
        publish(self.store, self.directory, lambda *_: None)
        self.assertEqual(self.store.calls[-1], PREFIX + '/stable/appcast.xml')

    def test_existing_version_cannot_be_overwritten(self):
        key = PREFIX + '/releases/0.11.0/checksums.txt'
        self.store.objects[key] = (b'previous artifact', 'different')
        with self.assertRaises(ValueError): publish(self.store, self.directory, lambda *_: None)
        self.assertEqual(self.store.calls, [])

    def test_downgrades_and_reused_build_numbers_are_rejected(self):
        previous = {'version': '0.10.0', 'build': 24}
        for version, build in [('0.9.0', 25), ('0.10.0', 25), ('0.11.0', 24), ('../bad', 25)]:
            with self.assertRaises(ValueError): validate_version(version, build, previous)
        validate_version('0.11.0', 25, previous)

    def test_feed_cannot_point_to_an_unrelated_download(self):
        path = self.directory / 'appcast.xml'
        path.write_text(path.read_text().replace(BASE_URL, 'https://unexpected.test'))
        with self.assertRaises(ValueError): validate_artifacts(self.directory)

    def test_missing_feed_signature_is_rejected(self):
        path = self.directory / 'appcast.xml'
        path.write_text(path.read_text().replace('sparkle-signatures:', 'not-a-signature:'))
        with self.assertRaises(ValueError): validate_artifacts(self.directory)

    def test_partial_previous_release_requires_repair(self):
        self.store.objects[PREFIX + '/stable/appcast.xml'] = (b'feed', 'hash')
        with self.assertRaises(ValueError): prepare(self.store, self.directory)

    def test_r2_credentials_cannot_be_sent_to_a_lookalike_host(self):
        with patch.dict('os.environ', {'R2_ENDPOINT': 'https://a.r2.cloudflarestorage.com.evil.test', 'AWS_ACCESS_KEY_ID': 'fixture', 'AWS_SECRET_ACCESS_KEY': 'fixture'}):
            with self.assertRaises(ValueError): R2()

    def test_production_configuration_requires_signed_feeds(self):
        info = app_info()
        self.assertEqual(info['CFBundleIdentifier'], 'io.bquick.explorer')
        self.assertTrue(info['SURequireSignedFeed'])
        self.assertFalse(info['ExplorerUpdatesEnabled'])


if __name__ == '__main__': unittest.main()
