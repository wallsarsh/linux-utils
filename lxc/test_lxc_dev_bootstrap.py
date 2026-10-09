#!/usr/bin/env python3
"""Safe unit tests for lxc-dev-bootstrap.sh: no system mutations."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('lxc-dev-bootstrap.sh')
SOURCE = SCRIPT.read_text().removesuffix('main "$@"\n')
SOURCE = SOURCE.replace('source /etc/os-release', 'source "$OS_RELEASE_FILE"')


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.stub = self.root / 'bin'
        self.stub.mkdir()
        self.log = self.root / 'commands.log'
        for name in ('pacman', 'pacman-key', 'apt-get', 'dnf', 'yum', 'zypper', 'docker'):
            path = self.stub / name
            path.write_text('#!/bin/sh\nprintf "%s %s\\n" "$(basename "$0")" "$*" >> "$CMD_LOG"\n')
            path.chmod(0o755)
        # A fake dynamic-linker cache tracks an initially installed runtime or
        # one supplied by the mocked package manager. Never modify the host.
        loader = self.stub / 'ldconfig'
        loader.write_text('#!/bin/sh\nprintf \'ldconfig %s\\n\' "$*" >> "$CMD_LOG"\n[ "${1:-}" = \'-p\' ] || exit 0\n[ "${ATOMIC_NO_PROVIDER:-false}" = true ] && exit 0\nif [ "${ATOMIC_PREINSTALLED:-false}" = true ] ||\n   grep -E \'^(apt-get|dnf|yum|zypper|pacman) .* (libatomic|libatomic1|gcc-libs)$\' "$CMD_LOG" >/dev/null 2>&1; then\n  printf \'  libatomic.so.1 (libc6,x86-64) => /lib64/libatomic.so.1\\n\'\nfi\n')
        loader.chmod(0o755)
        self.source = self.root / 'lib.sh'
        self.source.write_text(SOURCE)
        self.os_release = self.root / 'os-release'

    def run_bash(self, code, *, distro='debian', like='', version='12', upgrade=True,
                 atomic_preinstalled=False, atomic_no_provider=False):
        self.os_release.write_text(f'ID={distro}\nID_LIKE="{like}"\nVERSION_ID="{version}"\nVERSION_CODENAME=bookworm\nPRETTY_NAME="Test {distro}"\n')
        env = os.environ.copy()
        env.update({
            'OS_RELEASE_FILE': str(self.os_release),
            'CMD_LOG': str(self.log),
            'ATOMIC_PREINSTALLED': str(atomic_preinstalled).lower(),
            'ATOMIC_NO_PROVIDER': str(atomic_no_provider).lower(),
            'PATH': str(self.stub) + os.pathsep + env['PATH'],
        })
        result = subprocess.run(
            ['bash', '-c', f'source "$1"\nUPGRADE={str(upgrade).lower()}\n{code}', '_', str(self.source)],
            text=True, capture_output=True, env=env,
        )
        return result

    def test_detect_distribution_families(self):
        cases = [
            ('debian', '', 'debian|apt-get'),
            ('ubuntu', '', 'debian|apt-get'),
            ('linuxmint', '', 'debian|apt-get'),
            ('fedora', '', 'redhat|dnf'),
            ('rhel', '', 'redhat|dnf'),
            ('rocky', '', 'redhat|dnf'),
            ('almalinux', '', 'redhat|dnf'),
            ('centos', '', 'redhat|dnf'),
            ('opensuse-tumbleweed', '', 'suse|zypper'),
            ('opensuse-leap', '', 'suse|zypper'),
            ('arch', '', 'arch|pacman'),
            ('manjaro', '', 'arch|pacman'),
            ('derivative', 'ubuntu debian', 'debian|apt-get'),
        ]
        for distro, like, expected in cases:
            with self.subTest(distro=distro):
                p = self.run_bash('detect_os; printf "%s|%s" "$FAMILY" "$PKG"', distro=distro, like=like)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertTrue(p.stdout.endswith(expected), p.stdout)

    def test_unknown_distro_fails_before_work(self):
        p = self.run_bash('detect_os', distro='solaris')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('Unsupported distribution', p.stderr)

    def test_upgrade_debian_and_skip(self):
        for upgrade in (True, False):
            self.log.unlink(missing_ok=True)
            p = self.run_bash('detect_os; upgrade_system', upgrade=upgrade)
            self.assertEqual(p.returncode, 0, p.stderr)
            log = self.log.read_text()
            self.assertIn('apt-get update', log)
            self.assertEqual('apt-get upgrade -y' in log, upgrade)

    def test_redhat_package_manager_upgrade_or_cache(self):
        for upgrade in (True, False):
            self.log.unlink(missing_ok=True)
            p = self.run_bash('detect_os; upgrade_system', distro='rocky', upgrade=upgrade)
            self.assertEqual(p.returncode, 0, p.stderr)
            log = self.log.read_text()
            self.assertIn('dnf -y upgrade' if upgrade else 'dnf -y makecache', log)

    def test_opensuse_upgrade_variation(self):
        for distro, expected in [('opensuse-tumbleweed', 'dup'), ('opensuse-leap', 'update')]:
            self.log.unlink(missing_ok=True)
            p = self.run_bash('detect_os; upgrade_system', distro=distro)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn('zypper --non-interactive ' + expected, self.log.read_text())

    def test_arch_keyring_and_full_upgrade(self):
        p = self.run_bash('detect_os; upgrade_system', distro='arch')
        self.assertEqual(p.returncode, 0, p.stderr)
        log = self.log.read_text()
        self.assertIn('pacman -Sy --needed --noconfirm archlinux-keyring', log)
        self.assertIn('pacman -Su --noconfirm', log)
        self.assertLess(log.index('archlinux-keyring'), log.index('pacman -Su'))

    def test_arch_skip_upgrade_rejected(self):
        p = self.run_bash('detect_os', distro='arch', upgrade=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('partial upgrades are unsupported', p.stderr)

    def test_package_mappings(self):
        for distro, expect in [
            ('ubuntu', 'apt-get install -y --no-install-recommends foo bar'),
            ('fedora', 'dnf -y install foo bar'),
            ('opensuse-leap', 'zypper --non-interactive install --no-recommends foo bar'),
            ('arch', 'pacman -S --needed --noconfirm foo bar'),
        ]:
            with self.subTest(distro=distro):
                self.log.unlink(missing_ok=True)
                p = self.run_bash('detect_os; pkg_install foo bar', distro=distro)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertIn(expect, self.log.read_text())

    def test_option_handling_and_validation(self):
        p = self.run_bash('parse_args --user dev --no-docker --no-services --sudo-mode password; printf "%s|%s|%s|%s" "$DEV_USER" "$INSTALL_DOCKER" "$START_SERVICES" "$SUDO_MODE"')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(p.stdout.endswith('dev|false|false|password'), p.stdout)
        p = self.run_bash('parse_args --user root')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('Invalid developer username', p.stderr)
        p = self.run_bash('parse_args --user dev --sudo-mode invalid')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('Invalid --sudo-mode', p.stderr)

    def test_docker_repo_selection(self):
        variants = [
            ('ubuntu', 'apt:ubuntu'),
            ('debian', 'apt:debian'),
            ('fedora', 'rpm:fedora'),
            ('rhel', 'rpm:rhel'),
            ('rocky', 'rpm:centos'),
            ('almalinux', 'rpm:centos'),
            ('opensuse-tumbleweed', 'distro'),
            ('arch', 'distro'),
            ('linuxmint', 'distro'),
        ]
        for distro, expected in variants:
            with self.subTest(distro=distro):
                code = '''detect_os
                setup_apt_docker_repo() { printf 'apt:%s\n' "$1"; }
                setup_rpm_docker_repo() { printf 'rpm:%s\n' "$1"; }
                pkg_install() { :; }
                install_distro_docker() { printf 'distro\n'; }
                install_docker'''
                p = self.run_bash(code, distro=distro)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertIn(expected, p.stdout)

    def test_docker_official_mapping_rejects_unmapped_derivative(self):
        code = 'detect_os; DOCKER_SOURCE=official; install_docker'
        p = self.run_bash(code, distro='linuxmint')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('not defined', p.stderr)

    def test_yay_opt_in_arch_only(self):
        p = self.run_bash('INSTALL_YAY=true; detect_os', distro='ubuntu')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('only on Arch', p.stderr)

    def test_as_dev_changes_from_inaccessible_root_cwd(self):
        """Regression: child user must not inherit a root-only cwd."""
        import pwd
        if os.geteuid() != 0:
            self.skipTest('Real UID switching requires root')
        try:
            pwd.getpwnam('nobody')
        except KeyError:
            self.skipTest('System has no nobody account')
        private_cwd = self.root / 'root-private'
        private_cwd.mkdir(mode=0o700)
        p = subprocess.run(
            ['bash', '-c', '''source "$1"
                DEV_USER=nobody
                DEV_HOME=/tmp
                cd -- "$2"
                before=$PWD
                as_dev bash -c 'test "$PWD" = "$HOME" && stat . >/dev/null'
                test "$PWD" = "$before"
            ''', '_', str(self.source), str(private_cwd)],
            text=True, capture_output=True,
        )
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_as_dev_go_version_from_inaccessible_root_cwd(self):
        """Integration regression for Go 'stat .' failing after runuser."""
        import pwd
        import shutil
        if os.geteuid() != 0:
            self.skipTest('Real UID switching requires root')
        if shutil.which('go') is None:
            self.skipTest('Go is not installed on test host')
        try:
            pwd.getpwnam('nobody')
        except KeyError:
            self.skipTest('System has no nobody account')
        private_cwd = self.root / 'private-go'
        private_cwd.mkdir(mode=0o700)
        p = subprocess.run(
            ['bash', '-c', '''source "$1"
                DEV_USER=nobody
                DEV_HOME=/tmp
                cd -- "$2"
                as_dev go version
            ''', '_', str(self.source), str(private_cwd)],
            text=True, capture_output=True,
        )
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('go version', p.stdout)

    def test_libatomic_distro_mapping_when_missing(self):
        for distro, package in [
            ('almalinux', 'libatomic'),
            ('rhel', 'libatomic'),
            ('rocky', 'libatomic'),
            ('fedora', 'libatomic'),
            ('centos', 'libatomic'),
            ('ubuntu', 'libatomic1'),
            ('debian', 'libatomic1'),
            ('opensuse-leap', 'libatomic1'),
            ('opensuse-tumbleweed', 'libatomic1'),
            ('arch', 'libatomic'),
        ]:
            with self.subTest(distro=distro):
                self.log.unlink(missing_ok=True)
                p = self.run_bash('detect_os; install_node_runtime_deps', distro=distro)
                self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
                commands = self.log.read_text()
                self.assertIn(' install ' if distro != 'arch' else 'pacman -S ', commands)
                self.assertIn(package, commands)
                self.assertIn('ldconfig -p', commands)
                self.assertIn('ldconfig \n', commands)

    def test_libatomic_already_available_skips_package_install(self):
        self.log.unlink(missing_ok=True)
        p = self.run_bash('detect_os; install_node_runtime_deps', distro='almalinux', atomic_preinstalled=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertNotIn('dnf -y install', self.log.read_text())
        self.assertIn('no additional package required', p.stdout)

    def test_libatomic_legacy_arch_falls_back_to_gcc_libs(self):
        self.log.unlink(missing_ok=True)
        p = self.run_bash('detect_os; pkg_has() { return 1; }; install_node_runtime_deps', distro='arch')
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn('pacman -S --needed --noconfirm gcc-libs', self.log.read_text())

    def test_libatomic_unavailable_after_install_fails_loudly(self):
        self.log.unlink(missing_ok=True)
        p = self.run_bash('detect_os; install_node_runtime_deps', distro='almalinux', atomic_no_provider=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('still missing after installing libatomic', p.stderr)

    def test_libatomic_setup_precedes_nvm_and_user_config(self):
        script = SCRIPT.read_text()
        main = script.split('main() {', 1)[1]
        self.assertLess(main.index('install_tools\n'), main.index('install_node_runtime_deps\n'))
        self.assertLess(main.index('install_node_runtime_deps\n'), main.index('setup_user_shell\n'))

    def test_no_password_leak_into_log_option(self):
        p = subprocess.run([str(SCRIPT), '--help'], text=True, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('--password-stdin', p.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
