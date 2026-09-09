"""Exercise bootstrap helpers without running package installs or provisioning."""
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = (Path(__file__).resolve().parents[1] / 'bootstrap.sh').read_text()


def function(name):
    match = re.search(rf'^{name}\(\) \{{\n.*?^\}}$', SCRIPT, re.M | re.S)
    if not match:
        raise AssertionError(f'Missing shell function: {name}')
    return match.group()


class BootstrapTest(unittest.TestCase):
    def run_shell(self, body, *args, helpers=()):
        source = 'set -euo pipefail\n'
        source += 'log() { :; }; ok() { :; }; warn() { :; }; die() { exit 1; };\n'
        source += '\n'.join(function(name) for name in helpers) + '\n' + body
        return subprocess.run(['bash', '-c', source, 'test', *args], capture_output=True, text=True)

    def test_github_url_normalization(self):
        for url in ('https://github.com/owner/repo', 'https://github.com/owner/repo.git/',
                    'git@github.com:owner/repo.git'):
            with self.subTest(url=url):
                result = self.run_shell('to_ssh_url "$1"', url,
                                        helpers=('to_plain_https_url', 'to_ssh_url'))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, 'git@github.com:owner/repo.git')

    def test_invalid_repo_urls_fail(self):
        for url in ('git@example.com:owner/repo', 'https://github.com/owner',
                    'https://github.com/owner/repo/tree/main', 'https://github.com/owner/..',
                    'https://github.com/owner/repo?token=test', '-upload-pack=command'):
            with self.subTest(url=url):
                result = self.run_shell('to_ssh_url "$1"', url,
                                        helpers=('to_plain_https_url', 'to_ssh_url'))
                self.assertNotEqual(result.returncode, 0)

    def test_existing_untrusted_host_key_stops_bootstrap(self):
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / 'key'
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
            known_hosts = Path(tmp) / 'known_hosts'
            original = 'github.com ' + key.with_suffix('.pub').read_text()
            known_hosts.write_text(original)
            result = self.run_shell('''
GITHUB_HOST_FP_ED25519=expected
GITHUB_HOST_FP_ECDSA=expected
GITHUB_HOST_FP_RSA=expected
verify_and_pin_github_host_key "$1"
''', str(known_hosts), helpers=('verify_and_pin_github_host_key',))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(known_hosts.read_text(), original)

    def test_repository_update_failure_stops_provisioning(self):
        start = SCRIPT.index('if [[ -d "${APP_DIR}/.git" ]]; then')
        end = SCRIPT.index('\nreadonly INFRA_DIR=', start)
        update_block = SCRIPT[start:end]
        for failed_action in ('remote', 'pull'):
            with self.subTest(action=failed_action), tempfile.TemporaryDirectory() as tmp:
                (Path(tmp) / '.git').mkdir()
                result = self.run_shell('''
APP_DIR="$1"
CLONE_URL=https://github.com/owner/repo.git
FAILED_ACTION="$2"
git() { local arg; for arg; do [[ "$arg" != "$FAILED_ACTION" ]] || return 1; done; }
scrub_origin_credentials() { :; }
''' + update_block + '\nprintf reached-provisioning', tmp, failed_action)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('reached-provisioning', result.stdout)


if __name__ == '__main__':
    unittest.main()
