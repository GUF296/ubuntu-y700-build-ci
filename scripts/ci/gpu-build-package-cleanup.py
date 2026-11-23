#!/usr/bin/env python3
"""Roll back only packages newly installed by the GPU compiler transaction."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess as sp
import sys

STATE = Path('/root/.tb321fu-gpu-package-state')
RECORDER = '/root/ci-apt-transaction.sh'
PROVENANCE = '/var/lib/tb321fu-build-provenance/apt-transactions'
GPU = 'tb321fu-ksystemstats-gpu'
NAME = re.compile(r'[a-z0-9][a-z0-9.+-]*(?::[a-z0-9][a-z0-9-]*)?')


def require(ok, why):
    if not ok:
        raise ValueError(why)


def resolve(label, state):
    if label in state:
        return label
    qualified = [n for n in state if n.split(':')[0] == label.split(':')[0] and
                 (':' not in label or state[n][1] == label.split(':')[1])]
    require(len(qualified) == 1, 'ambiguous or missing installed package: ' + label)
    return qualified[0]


def snapshot():
    fields = r'${db:Status-Abbrev}\t${binary:Package}\t${Version}\t${Architecture}\t${Essential}\t${Protected}\n'
    text = sp.check_output(['dpkg-query','-W','-f='+fields],text=True)
    state = {}
    for line in text.splitlines():
        status, name, version, arch, essential, protected = line.split('\t')
        if status[1] != 'i':
            continue
        require(len(status)==3 and status[2]==' ' and NAME.fullmatch(name) and name not in state,
                'unexpected installed dpkg state')
        state[name] = [version,arch,False,status[0]=='h' or essential=='yes' or protected=='yes']
    require(0 < len(state) <= 32768, 'unexpected installed package count')
    for name in sp.check_output(['apt-mark','showauto'],text=True).splitlines():
        # apt-mark showauto reports installed package marks only.
        state[resolve(name,state)][2] = True
    return state


def preserve(before, now):
    require(all(now.get(n) == row for n,row in before.items()),
            'a pre-existing package version, architecture, mark or protection changed')


def simulate(names, allowed, now, executable=('apt-get',)):
    # Same target apt resolver/configuration as the attested purge below. Any
    # protected removal or new configuration/install makes this subset unsafe.
    proc = sp.run([*executable,'-s','purge','-y','--',*names],capture_output=True,text=True,timeout=60)
    require(proc.returncode==0,'target APT failed to simulate the GPU removal request')
    removed=set()
    for row in proc.stdout.splitlines():
        if row.startswith(('Inst ','Conf ')):
            return None
        if row.startswith(('Purg ','Remv ')):
            item=resolve(row.split()[1],now)
            if item not in allowed:
                return None
            require(item not in removed,'duplicate simulated removal')
            removed.add(item)
    return removed if set(names)<=removed else None


def plan(allowed, probe):
    # Try the common one-transaction case first. If a true runtime dependency
    # blocks it, bisect and grow only solver-approved subsets; retain packages
    # whose removal would cost any pre-existing package or the plugin.
    accepted=set()
    def attempt(group):
        nonlocal accepted
        group=sorted(set(group)-accepted)
        if not group:
            return
        proposed=accepted|set(group)
        actual=probe(sorted(proposed))
        if actual is not None:
            require(proposed<=actual<=allowed,'out-of-scope resolver result')
            accepted=actual
        elif len(group)>1:
            i=len(group)//2
            attempt(group[:i]);attempt(group[i:])
    attempt(allowed)
    return accepted


def main(mode):
    os.environ['LC_ALL']='C'
    require(mode in ('before','after-install','cleanup'),'invalid GPU cleanup operation')
    now=snapshot()
    if mode=='before':
        STATE.mkdir(mode=0o700)
        (STATE/'before').write_text(json.dumps(now))
        return
    before=json.loads((STATE/'before').read_text())
    preserve(before,now)
    if mode=='after-install':
        added={n:v for n,v in now.items() if n not in before}
        require(len(added)<=256,'GPU build introduced too many packages')
        with (STATE/'added').open('x') as out:
            json.dump(added,out)
        return
    added=json.loads((STATE/'added').read_text())
    require(isinstance(added,dict) and len(added)<=256 and not (set(added)&set(before)),
            'invalid GPU compiler package checkpoint')
    require(GPU in now,'GPU runtime package is absent before cleanup')
    require(all(n in now and now[n][:2]==v[:2] for n,v in added.items()),
            'build packages changed before cleanup')
    allowed={n for n in added if n!=GPU and not now[n][3] and now[n][2]}
    probe=lambda names: simulate(names,allowed,now)
    removed=plan(allowed,probe)
    if removed:
        require(probe(sorted(removed))==removed,'final removal plan changed')
        for path,key in [(RECORDER,'CI_APT_RECORDER_SHA256'),('/root/ci-apt-common.sh','CI_APT_COMMON_SHA256')]:
            with open(path,'rb') as f:
                require(hashlib.file_digest(f,'sha256').hexdigest()==os.environ[key],'untrusted APT recorder')
        sp.run([RECORDER,PROVENANCE,'gpu-build','purge','-y','--',*sorted(removed)],check=True)
    final=snapshot()
    require(set(now)-set(final)==removed and set(final)<=set(now),'actual removals differ from scoped plan')
    preserve({n:v for n,v in now.items() if n not in removed},final)
    print('GPU_BUILD_PACKAGES=PASS introduced=%d removed=%d retained=%d'%(len(added),len(removed),len(added)-len(removed)))
    (STATE/'added').unlink();(STATE/'before').unlink();STATE.rmdir()


if __name__=='__main__':
    main(sys.argv[1])
