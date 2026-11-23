"""Cloud-only immutable input and numeric draft checks. Assembled with the reviewed common functions."""
import hashlib,json,os,re,shutil,subprocess as sp,tempfile,time,zipfile
from pathlib import Path
RUN=44962218886
H='cedd5879ff3de5de0dc86a03eb82ea2cea5ac0a6'
ID=14731227846
RID=454078974
SIZE=3290876337
DIGEST='91db68ff761004d4c9d0dadb3563613cee384167a52aec2f66f3e2ddc9a7998d'
repo='GUF296/ubuntu-y700-build-ci'
api='repos/'+repo
def need(ok,msg):
    if not ok:raise ValueError(msg)
def get(route):
    for attempt in range(3):
        try:return json.loads(sp.check_output(['gh','api','--hostname','github.com','--method','GET',api+'/'+route],timeout=35,stderr=sp.DEVNULL))
        except (sp.CalledProcessError,sp.TimeoutExpired):
            if attempt==2:raise
            time.sleep(1+attempt)
def find_release_id():
    text=sp.check_output(['gh','api','--paginate',api+'/releases?per_page=100','--jq','.[] | [.tag_name,.id] | @tsv'],text=True,timeout=60)
    ids=[int(l.split('\t')[1]) for l in text.splitlines() if l.split('\t')[0]==TAG]
    need(ids==[RID],'numeric draft match missing');return RID
def no_tag(h,draft):
    need(h==H and draft is True and not any(x['ref']=='refs/tags/'+TAG for x in get('git/matching-refs/tags/'+TAG)),'private tag no longer absent')
def protected():
    stable=get('releases/latest')
    need((stable['id'],stable['tag_name'],stable['draft'],stable['prerelease'])==(346132226,OLD,False,False),'June release changed')
    need({a['name']:(a['id'],a['size'],a['updated_at']) for a in stable['assets']}==JUNE_OBJECTS and
         {a['name']:a['digest'] for a in stable['assets']}=={k:'sha256:'+v for k,v in OLD_ASSETS.items()},'June assets changed')
    for uri in ('git/ref/heads/main','git/ref/tags/'+OLD):
        need(get(uri)['object']=={'sha':OLD_MAIN,'type':'commit','url':'https://api.github.com/'+api+'/git/commits/'+OLD_MAIN},'June ref changed')
def registration():
    a=get('actions/artifacts/'+str(ID));r=get('actions/runs/'+str(RUN))
    need((a['name'],a['id'],a['expired'],a['digest'],a['size_in_bytes'],a['workflow_run']['id'],a['workflow_run']['head_sha'])==
        ('release-staging-44962218886-1',ID,False,'sha256:'+DIGEST,SIZE,RUN,H),'wrong staging artifact')
    need((r['repository']['id'],r['id'],r['head_sha'],r['head_branch'],r['run_attempt'],r['workflow_id'],r['status'],r['conclusion'])==
        (1279887367,RUN,H,'codex/full-remediation-20260715',1,301941893,'completed','failure'),'wrong original run')
    jobs=get(f'actions/runs/{RUN}/attempts/1/jobs?per_page=100')
    need(jobs['total_count']==3 and {j['name']:(j['id'],j['conclusion']) for j in jobs['jobs']}==
         {'camera-producer':(137023310366,'success'),'build':(137024702363,'success'),'publish':(137033699886,'failure')},'incomplete native build')
def main():
    need(os.environ['GITHUB_REPOSITORY']==repo and os.environ['GITHUB_REF']=='refs/heads/codex/r10-staged-upload-44962218886' and
         os.environ['GITHUB_RUN_ATTEMPT']=='1' and sp.check_output(['git','rev-parse','HEAD'],text=True).strip()==os.environ['GITHUB_SHA'],'wrong recovery invocation')
    protected();registration();no_tag(H,True)
    with tempfile.TemporaryDirectory(dir=os.environ['RUNNER_TEMP']) as d:
        path=Path(d)/'stage.zip'
        with path.open('xb') as out:
            sp.run(['gh','api','--method','GET',api+f'/actions/artifacts/{ID}/zip'],stdout=out,check=True,timeout=780)
        with path.open('rb') as f:need(path.stat().st_size==SIZE and hashlib.file_digest(f,'sha256').hexdigest()==DIGEST,'stage bytes mismatch')
        with zipfile.ZipFile(path) as z:
            expected,notes=inventory(z);initial=state(expected,notes)
            need(initial.keys()==set(ORIGINAL),'expected exactly the 22 original assets before starting')
            print('Original staged ZIP and all 25 inner digests verified; preserving original 22 assets.',flush=True)
            for n in TAIL:
                before=state(expected,notes);need(before==initial and n not in before,'draft changed before transfer')
                print('Streaming',n,expected[n][0],flush=True)
                aid=upload(z,n,*expected[n]);after=state(expected,notes)
                need(after.keys()==before.keys()|{n} and all(after[k]==v for k,v in before.items()) and after[n][0]==aid,'wrong upload readback')
                initial=after;print('Verified',n,aid,flush=True)
            final=state(expected,notes);need(final.keys()==ALL,'missing files')
    protected();registration()
    data=(json.dumps(dict(schema='tb321fu.r10.owned-draft-recovery/v1',rid=RID,run=RUN,head=H,artifact=ID,
                artifact_digest=DIGEST,assets=final,original=ORIGINAL),sort_keys=True,indent=2)+'\n').encode()
    with Path('r10-complete-private-draft-454078974.json').open('xb') as f:f.write(data)
    print('R10_PRIVATE_DRAFT_COMPLETE',len(final),sha(data))

TAG = "tb321fu-kubuntu2604-remediation-20261120.1"
OLD = "tb321fu-kubuntu2604-fcitx5-plasma-keyboard-clean-20260629"
OLD_MAIN = "4f87bbc51c6e8ab4434d421bd16fac3f7a8cb1d3"
OLD_ASSETS = {
    "boot.img.7z": "a9c2e176b34d3205f8f71b5819c58d215dcb993395191d8d44f37d922f592b02",
    "grub.img.7z": "526daa1c50fc9fa8f7dc525d5f4b2133fe3362b70f23d14a01ef0ce922129045",
    "rootfs.img.7z.000": "19b047a48e7eda38a1f468ddb6fbd7f0145d8e851f8c3a54fb41d9b228ea2514",
    "rootfs.img.7z.001": "d27cf3b58a837d326f10ecf9bc18367337de247718ebba278ec86a07bebf6091",
    "SHA256SUMS.txt": "61f6772027c27ec2e743a20d96bf04f88ff80ec39ef46e0921b5582d855b9983",
}
JUNE_OBJECTS = {
    "boot.img.7z":(460905843,2429060,"2026-06-29T08:05:19Z"),
    "grub.img.7z":(460905845,13342814,"2026-06-29T08:05:20Z"),
    "rootfs.img.7z.000":(460905844,1992294400,"2026-06-29T08:06:49Z"),
    "rootfs.img.7z.001":(460905847,1293200522,"2026-06-29T08:06:19Z"),
    "SHA256SUMS.txt":(460905842,324,"2026-06-29T08:05:19Z"),
}
CAM='tb321fu-camera-stack_20261122.1_arm64.deb'
TAIL=(CAM,'rootfs.img.7z.000','rootfs.img.7z.001')
ORIGINAL=dict(zip(('APT-BOOTSTRAP.tsv','APT-PROVENANCE.tsv','APT-SOURCES.txt','boot.img.7z','BUILD-PARAMETERS.md',
    'CAMERA-BUILD-REPORT.txt','CAMERA-HANDOFF.tsv','grub.img.7z','HAPTICS-BUILD-TOOLS.tsv','HAPTICS-SOURCE-LOCK.tsv',
    'KBUILD-FLAGS.tsv','KERNEL-BUNDLE.tsv','KERNEL-SDK-MANIFEST.tsv','KERNEL-SOURCE-LOCK.tsv','KERNEL-TOOLCHAIN.tsv',
    'MODULES.sha256','ROOTFS-PACKAGES.tsv','SENSOR-SOURCE-LOCK.tsv','SHA256SUMS-tb321fu-camera-stack-debs.txt',
    'SHA256SUMS.txt','VERIFIED-BUNDLE.tsv','VERIFIED-INPUTS.tsv'),
    (777309647,777309661,777309671,777310018,777309689,777309700,777309727,777310050,777309745,777309764,777309783,
     777309799,777309810,777309827,777309836,777309852,777309882,777309912,777309939,777309956,777309976,777309999),strict=True))
ALL=set(ORIGINAL)|set(TAIL)
SHA='a94bf36c6f6c12dc295cc942a07a7ee5a6463cfd13e1c3f1977184892338944d'
sha=lambda b:hashlib.sha256(b).hexdigest()
def inventory(z):
    rows=z.infolist()
    files={r.filename.removeprefix('assets/'):r for r in rows if not r.is_dir()}
    need(files.keys()==ALL and all(x.filename=='assets/'+n for n,x in files.items()) and
         len(files)==sum(not x.is_dir() for x in rows) and all(x.filename=='assets/' for x in rows if x.is_dir()) and
         all(0<x.file_size<=1992294400 and x.compress_type in (0,8) and not x.flag_bits&1 for x in files.values()),'stage inventory differs')
    table=z.read(files['SHA256SUMS.txt']);need(sha(table)==SHA,'stage checksum file differs')
    matches=[re.fullmatch(rb'([a-f0-9]{64}) [ *](?:\./)?([A-Za-z0-9._-]+)',line) for line in table.splitlines()]
    need(all(matches) and len(matches)==len(ALL)-1,'malformed checksum list')
    digests={m[2].decode():m[1].decode() for m in matches}
    need(digests.keys()==ALL-{'SHA256SUMS.txt'},'wrong checksum list filenames')
    digests['SHA256SUMS.txt']=SHA
    for name,row in files.items():
        with z.open(row) as f:need(hashlib.file_digest(f,'sha256').hexdigest()==digests[name],'stage member differs: '+name)
    need(digests[CAM]=='803068f41884475af7f73db36079d8076ba04ae38931121a1dce54a8c182329b','not authenticated same-run camera')
    return {n:(r.file_size,digests[n]) for n,r in files.items()},z.read(files['BUILD-PARAMETERS.md']).decode()
def state(expected,notes):
    need(K['find_release_id']()==RID,'different release id')
    r=S['get'](f'releases/{RID}')
    need((r['id'],r['draft'],r['prerelease'],r['tag_name'],r['name'],r['target_commitish'],r['body'],r['upload_url'])==
         (RID,True,True,K['TAG'],K['TAG'],H,notes,f'https://uploads.github.com/repos/{repo}/releases/{RID}/assets{{?name,label}}'),'not the original partial draft')
    need(f'- Workflow run: `{RUN}`' in notes and f'- Commit: `{H}`' in notes,'stage metadata not bound to R10')
    assets={x['name']:x for x in r['assets']}
    need(len(assets)==len(r['assets']) and set(ORIGINAL)<=assets.keys()<=ALL and
         all(assets[n]['id']==v for n,v in ORIGINAL.items()),'prior asset identity changed')
    for n,a in assets.items():
        need(a['state']=='uploaded' and (a['size'],a['digest'])==(expected[n][0],'sha256:'+expected[n][1]),'incomplete or different asset: '+n)
    K['verify_tag_phase'](H,True)
    return {n:(a['id'],a['size'],a['digest']) for n,a in assets.items()}
def upload(z,n,sz,h):
    path=f'https://uploads.github.com/repos/{repo}/releases/{RID}/assets?name={n}'
    cmd=['/usr/bin/timeout','-k','3','35m','gh','api','--hostname','github.com','--method','POST',
         '-H','Content-Type: application/octet-stream','-H',f'Content-Length: {sz}',path,'--input','-']
    with z.open('assets/'+n) as src, sp.Popen(cmd,stdin=sp.PIPE,stdout=sp.PIPE,stderr=sp.DEVNULL) as proc:
        streamed=hashlib.sha256();count=0
        try:
            while b:=src.read(1<<20):
                proc.stdin.write(b);streamed.update(b);count+=len(b)
            proc.stdin.close(); result=proc.stdout.read(32769)
            need(len(result)<=32768 and proc.wait(timeout=120)==0,'upload returned error; inspect numeric draft before any retry')
        finally:
            if proc.poll() is None:proc.kill()
        a=json.loads(result)
    need(count==sz and streamed.hexdigest()==h and (a['state'],a['name'],a['size'],a['digest'])==('uploaded',n,sz,'sha256:'+h),'upload response mismatch')
    return a['id']

K={'TAG':TAG,'find_release_id':find_release_id,'verify_tag_phase':no_tag}
S={'get':get}
if __name__=='__main__':main()
