"""Prove the real local APT solver cannot sacrifice protected or unrelated package state."""
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch

G=runpy.run_path(str(Path(__file__).with_name('gpu-build-package-cleanup.py')))

class GPUPlan(unittest.TestCase):
    def test_kubuntu_desktop_roots(self):
        ci=Path(__file__).parent
        text=(ci/'build-rootfs-image.sh').read_text()
        begin=text.index('default_packages="')
        end=text.index('PACKAGE_LIST=$(ci_normalize_package_list "$PACKAGE_LIST")',begin)
        script='source "$1"; '+text[begin:end]+'ci_normalize_package_list "$PACKAGE_LIST"'
        roots={'binutils','bzip2','qt6-qmltooling-plugins'}
        for desktop,arch in [('kubuntu-desktop','arm64'),('kubuntu-desktop','amd64'),('plasma-desktop','arm64'),('','arm64')]:
            env=dict(os.environ,ARCH=arch,DESKTOP_ENV=desktop,PACKAGE_LIST='sudo',INSTALL_GNOME_SNAPSHOT='0',
                     INSTALL_FIREFOX='0',INSTALL_FCITX5_CHINESE='0')
            packages=set(subprocess.check_output(['bash','-eu','-c',script,'sh',str(ci/'common.sh')],
                                                  env=env,text=True).splitlines())
            self.assertTrue(({'sudo'}|({desktop} if desktop else set()))<=packages)
            self.assertEqual(packages&roots,roots if (desktop,arch)==('kubuntu-desktop','arm64') else set())

    def test_kubuntu_final_inventory(self):
        source=Path(__file__).with_name('build-rootfs-image.sh').read_text()
        block=source.split('# Check the real post-cleanup target,',1)[1].split('\n',1)[1].split('\nfi\n',1)[0]+'\nfi'
        names='binutils binutils-aarch64-linux-gnu binutils-common bzip2 libbinutils libctf-nobfd0 libctf0 libgprofng0 libsframe3 qt6-qmltooling-plugins'.split()
        with tempfile.TemporaryDirectory() as tmp:
            f=Path(tmp)/'inventory'
            def result(lines,desktop='kubuntu-desktop'):
                f.write_text(''.join(lines))
                return subprocess.run(['bash','-eu','-c','ci_die() { exit 77; }; '+block],
                                      env=dict(os.environ,ARCH='arm64',DESKTOP_ENV=desktop,package_inventory=str(f)),
                                      capture_output=True).returncode
            rows=[n+(':arm64' if i%2 else '')+'\t1\tarm64\n' for i,n in enumerate(names)]
            self.assertEqual(result(rows),0)
            for i in range(len(rows)):
                self.assertEqual(result(rows[:i]+rows[i+1:]),77)
            self.assertEqual(result(rows+[rows[0]]),77)
            self.assertEqual(result([rows[0].replace('arm64','amd64')]+rows[1:]),77)
            self.assertEqual(result([],'plasma-desktop'),0)

    def test_mixed_arch_and_hold(self):
        target='ii \tcompiler:arm64\t1\tarm64\t\t\nhi \tconsole\t2\tarm64\t\t\nii \tcommon\t1\tall\tyes\t\nrc \told\t1\tarm64\t\t\n'
        with patch('subprocess.check_output',side_effect=[target,'compiler\ncommon\n']):
            state=G['snapshot']()
        self.assertEqual(state,{'compiler:arm64':['1','arm64',True,False],
                               'console':['2','arm64',False,True], 'common':['1','all',True,True]})
        with self.assertRaises(ValueError):
            G['resolve']('lib',{'lib:i386':['1','i386'], 'lib:arm64':['1','arm64']})

    def test_scope(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td)
            for s in ('lists/partial','archive/partial','empty'):
                (p/s).mkdir(parents=True)
            pkgs={'desktop':'Depends: required\nSuggests: dev-tool','plugin':'Depends: runtime',
                  'required':'','runtime':'','dev-tool':'Depends: dev-lib','dev-lib':'','other-auto':''}
            def row(name,extra):
                return (f'Package: {name}\nStatus: install ok installed\nPriority: optional\nSection: misc\n'
                        f'Architecture: arm64\nVersion: 1\nMaintainer: Fixture <example@example.invalid>\n'
                        'Description: fixture\n'+(extra+'\n' if extra else '')+'\n')
            (p/'status').write_text(''.join(row(n,x) for n,x in pkgs.items()))
            (p/'apt.conf').write_text(f'''Dir::Etc::parts "-"; Dir::Etc::main "/dev/null";
Dir::Etc::sourcelist "/dev/null"; Dir::Etc::sourceparts "{p}/empty";
Dir::State::status "{p}/status"; Dir::State::lists "{p}/lists";
Dir::State::extended_states "{p}/marks"; Dir::Cache::archives "{p}/archive";
Dir::Cache::pkgcache ""; Dir::Cache::srcpkgcache ""; APT::Architecture "arm64";
APT::Architectures {{ "arm64"; }};
''')
            (p/'marks').write_text('Package: other-auto\nArchitecture: arm64\nAuto-Installed: 1\n')
            state={n:['1','arm64',True,False] for n in pkgs}
            allowed={'dev-tool','dev-lib','runtime','required'}
            with patch.dict(os.environ,{'APT_CONFIG':str(p/'apt.conf'),'LC_ALL':'C'}):
                probe=lambda ns:G['simulate'](ns,allowed,state)
                self.assertIsNone(probe(['runtime']))
                self.assertIsNone(probe(['required']))
                self.assertEqual(G['plan'](allowed,probe),{'dev-tool','dev-lib'})
                self.assertNotIn('other-auto',probe(['dev-tool']))
        self.assertEqual(G['plan'](set(),lambda _:self.fail()),set())
        with self.assertRaises(ValueError):
            G['preserve']({'before':['1','arm64',True,False]},{'before':['1','arm64',False,False]})
        with self.assertRaises(ValueError):
            G['plan']({'new'},lambda _:{'new','old'})

if __name__=='__main__':
    unittest.main()
