"""Prove the real local APT solver cannot sacrifice protected or unrelated package state."""
import os
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch

G=runpy.run_path(str(Path(__file__).with_name('gpu-build-package-cleanup.py')))

class GPUPlan(unittest.TestCase):
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
