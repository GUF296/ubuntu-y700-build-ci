"""Cloud readback. Never mount the image, never run its payload or export unfiltered input."""
import bisect,collections,hashlib,json,lzma,mmap,os,re,resource,signal,stat,struct,sys,tempfile,time,zlib
import subprocess as sp
from pathlib import Path
REPO='GUF296/ubuntu-y700-build-ci';API='repos/'+REPO;RUN=44962218886;RID=454078974
H='cedd5879ff3de5de0dc86a03eb82ea2cea5ac0a6'; BR='codex/r10-private-image-readback-44962218886'
TAIL=('rootfs.img.7z.000','rootfs.img.7z.001')
RELATIONS={'Depends','Pre-Depends','Recommends','Suggests','Enhances','Breaks','Conflicts','Replaces','Provides'}
ORDER=('Package','Status','Priority','Section','Architecture','Version','Config-Version','Multi-Arch','Essential','Protected','Pre-Depends','Depends','Recommends','Suggests','Enhances','Breaks','Conflicts','Replaces','Provides')
CODE='[a-z0-9][a-z0-9+.\\-]*';VER='[0-9a-zA-Z][0-9A-Za-z.+:~\\-]*'
ATOM=CODE+r'(?::(?:[a-z0-9][a-z0-9-]*))?(?:\s*\(\s*(?:<<|<=|>=|>>|=|<|>)\s*'+VER+r'\s*\))?'

def need(v,m):
    if not v:raise ValueError(m)

def get(path):
    return json.loads(sp.check_output(['gh','api','--hostname','github.com','--method','GET',API+'/'+path],stderr=sp.DEVNULL,timeout=50))

def blocks(raw):
    need(0<len(raw)<=3<<20 and b'\0' not in raw and b'\r' not in raw,'invalid package metadata')
    for rec in raw.strip(b'\n').split(b'\n\n'):
        result={};current=None
        for row in rec.split(b'\n'):
            if row.startswith((b' ',b'\t')):
                need(current is not None,'continued field without name')
                if current in result:result[current]+=b' '+row.strip()
                continue
            k,sep,val=row.partition(b':');need(sep and re.fullmatch(rb'[A-Za-z0-9][A-Za-z0-9-]+',k),'unexpected field name')
            current=k.decode('ascii')
            if current in ORDER or current=='Auto-Installed':
                need(current not in result,'duplicate selected field')
                result[current]=val.strip()
        yield {k:v.decode('ascii') for k,v in result.items()}

def sanitized(status,ext,packages):
    rawlist=packages.decode('ascii').splitlines();rows=[s.split('\t') for s in rawlist]
    need(len(rows)==1974 and all(len(r)==3 for r in rows),'wrong original inventory')
    ref={(n.split(':')[0],arch):version for n,version,arch in rows}
    need(len(ref)==1974,'duplicate installed package tuples')
    installed={};seen=set();ans=[]
    for d in blocks(status):
        need({'Package','Status','Architecture','Version'}<=d.keys() and not (d.keys()-set(ORDER)),'invalid status entry')
        n,a=d['Package'],d['Architecture'];ident=(n,a)
        need(ident not in seen and re.fullmatch(CODE,n) and a in ('arm64','all'),'unexpected package identity');seen.add(ident)
        for k,v in d.items():
            need(v.isascii() and v.isprintable() and len(v)<=32768,'unexpected solver value shape')
            if k in RELATIONS:
                need(all(re.fullmatch(ATOM,item.strip()) for grp in v.split(',') for item in grp.split('|')),'invalid dependency field '+k+' for '+n)
            elif k in ('Version','Config-Version'):need(re.fullmatch(VER,v),'invalid package version')
            elif k=='Status':need(re.fullmatch(r'(?:install|hold|deinstall|purge|unknown) (?:ok|reinstreq) (?:installed|not-installed|config-files|half-installed|unpacked|half-configured|triggers-awaited|triggers-pending)',v),'invalid dpkg state')
            elif k in ('Essential','Protected'):need(v in ('no','yes'),'invalid package role')
            elif k=='Multi-Arch':need(v in ('no','same','foreign','allowed'),'unexpected multiarch')
            elif k in ('Priority','Section'):need(re.fullmatch(r'[a-zA-Z0-9][-a-zA-Z0-9+/_.]*',v),'invalid public classification')
        if d['Status']=='install ok installed':installed[ident]=d['Version']
        # Do not include original Descriptions, Maintainers, Conffiles, paths, hashes or comments.
        ans.append('\n'.join(k+': '+d[k] for k in ORDER if k in d)+'\nDescription: package solver projection only\n')
    need(installed==ref,'final image package inventory does not match staged package list')
    marks=[];seen_auto=set()
    for d in blocks(ext):
        need(set(d) in ({'Package','Architecture','Auto-Installed'},{'Package','Architecture'}) and
             re.fullmatch(CODE,d['Package']) and re.fullmatch(r'(?:any|all|arm64)',d['Architecture']) and
             d.get('Auto-Installed','0') in ('0','1'),'invalid public APT automatic flag')
        key=d['Package'],d['Architecture'];need(key not in seen_auto,'duplicate APT marker');seen_auto.add(key)
        marks.append('\n'.join(k+': '+d[k] for k in ('Package','Architecture','Auto-Installed') if k in d)+'\n')
    return ('\n'.join(ans)+'\n').encode(),('\n'.join(marks)+'\n').encode(),len(seen),len(marks)

"""Stage transport only. Sizes/digests are compared with the previously verified private release IDs."""
def stage():
    id=14731227846;wanted='release-staging-44962218886-1'
    page=get(f'actions/runs/{RUN}/artifacts?per_page=100')
    need(page['total_count']==len(page['artifacts'])<=8,'incomplete original artifact listing')
    one=[a for a in page['artifacts'] if a['name']==wanted]
    need(len(one)==1,'no unique original stage')
    for a in [one[0],get(f'actions/artifacts/{id}')]:
        w=a['workflow_run']
        need((a['id'],a['name'],a['size_in_bytes'],a['digest'],a['expired'],w['id'],w['head_sha'],w['repository_id'],w['head_repository_id'])==
             (id,wanted,3290876337,'sha256:91db68ff761004d4c9d0dadb3563613cee384167a52aec2f66f3e2ddc9a7998d',False,
              RUN,H,1279887367,1279887367),'unexpected stage registration')
    return one[0]

def stage_input(d,path):
    import zipfile
    a=stage();tmp=Path(d)/'staging.zip'
    with tmp.open('xb') as f:
        n=0;h=hashlib.sha256()
        with sp.Popen(['timeout','-k','3','900','gh','api','--hostname','github.com','--method','GET',API+f"/actions/artifacts/{a['id']}/zip"],
                stdin=sp.DEVNULL,stdout=sp.PIPE,stderr=sp.DEVNULL) as proc:
            try:
                for b in iter(lambda:proc.stdout.read(1<<20),b''):
                    n+=len(b);need(n<=a['size_in_bytes'],'staging file too large');f.write(b);h.update(b)
                need(proc.wait(timeout=15)==0 and n==a['size_in_bytes'] and 'sha256:'+h.hexdigest()==a['digest'],'staged ZIP transfer failed or hash differs')
            finally:
                if proc.poll() is None:proc.kill();proc.wait()
    with zipfile.ZipFile(tmp) as z:
        members={r.filename.removeprefix('assets/'):r for r in z.infolist() if not r.is_dir()}
        need(len([r for r in z.infolist() if not r.is_dir()])==len(members)==25 and members.keys()==EXPECTED_ASSETS.keys() and
             all(r.filename=='assets/'+n and r.file_size==EXPECTED_ASSETS[n][1] and r.compress_type in (0,8) and not r.flag_bits&1 for n,r in members.items()),'unexpected staged membership')
        def read(name,out):
            r=members[name]; h=hashlib.sha256();total=0
            with z.open(r) as f:
                for b in iter(lambda:f.read(1<<20),b''):
                    total+=len(b);need(total<=r.file_size,'staged payload too large');h.update(b);out(b)
            need(total==r.file_size and 'sha256:'+h.hexdigest()==EXPECTED_ASSETS[name][2],'selected staged content differs from private release: '+name)
        notes=bytearray();pkg=bytearray()
        read('BUILD-PARAMETERS.md',notes.extend);read('ROOTFS-PACKAGES.tsv',pkg.extend)
        zsha=hashlib.sha256()
        with path.open('xb') as f:
            def update(b):f.write(b);zsha.update(b)
            for n in TAIL:read(n,update)
    tmp.unlink()  # owned temporary runner file, after verified selected data closed; not a raw image
    print('Verified complete original stage ZIP, both R10 rootfs volumes and two metadata assets',flush=True)
    return notes,pkg,zsha

def main():
    need(os.environ.get('GITHUB_REPOSITORY')==REPO and os.environ.get('GITHUB_REF')=='refs/heads/'+BR and
         os.environ.get('GITHUB_RUN_ATTEMPT')=='1' and os.environ.get('GITHUB_EVENT_NAME')=='workflow_dispatch' and
         re.fullmatch(r'[a-f0-9]{40}',os.environ.get('GITHUB_SHA','')),'incorrect read-only invocation')
    with tempfile.TemporaryDirectory(dir=os.environ['RUNNER_TEMP']) as d:
        path=Path(d)/'rootfs.7z'
        notes,pkg,zsha=stage_input(d,path)
        marker=re.findall(rb'^## SSH host identity evidence\n```json\n([^\n]+)\n```$',notes,re.M)
        need(len(marker)==1,'no unique typed build descriptor')
        ctx=json.loads(marker[0]);need(ctx['schema']=='tb321fu.ssh-image/v1','wrong evidence schema')
        need(all(re.fullmatch('[a-f0-9]{64}',ctx[n]) for n in ('archive_sha256','raw_sha256')),'invalid image digests')
        need(zsha.hexdigest()==ctx['archive_sha256'],'joined image differs')
        proof=_verify_raw(path,ctx['raw_sha256'],RAW_SIZE);proof.update(archive_sha256=zsha.hexdigest(),archive_size=path.stat().st_size)
        print('All rootfs volumes, combined archive and complete 20 GiB raw SHA-256 verified',flush=True)
        packed,dictionary=archive_fields(path,proof)
        with path.open('rb') as f,mmap.mmap(f.fileno(),0,access=mmap.ACCESS_READ) as mm:
            def fresh():return Files(Stream(mm,packed,dictionary,RAW_SIZE))
            fs=fresh()
            def public(fsys,p):
                return bytes(fsys.data(fsys.leaf(p),False))
            status=public(fs,'var/lib/dpkg/status');extended=public(fs,'var/lib/apt/extended_states')
            st,es,n,marks=sanitized(status,extended,pkg)
            report=dict(schema='tb321fu.r10.cloud-selected-apt/v1',original_run=RUN,head=H,helper_sha=os.environ['GITHUB_SHA'],
                        helper_run=int(os.environ['GITHUB_RUN_ID']),draft=RID,rootfs=proof,installed=1974,package_rows=n,apt_markers=marks,
                        sanitized_status_sha256=hashlib.sha256(st).hexdigest(),sanitized_extended_sha256=hashlib.sha256(es).hexdigest(),
                        apt_comparison='Exact Package+Version+Architecture against the 1974 actual published-build inventory entries, not dependency simulation.')
            # Only private candidate board payloads that already have locked release-package SHA-256.
            fs=fresh();matches={}
            try:
                for name,expected in PUBLIC_FILES.items():
                    ino=fs.leaf(name);mode,_,_=fs.inode(ino)
                    need(mode==stat.S_IFREG|expected[0] and hashlib.sha256(bytes(fs.data(ino,False))).hexdigest()==expected[1],'selected board runtime file differs: '+name)
                    matches[name]=expected[1]
                report['native_directories']=inspect(fresh());report['board_supplement']='PASS'
            except (ValueError,OSError,struct.error,lzma.LZMAError):
                # A separately labelled supplementary mismatch cannot erase the verified solver state.
                report['board_supplement']='INCOMPLETE';print('Board supplemental read incomplete; not a pass',flush=True)
            report['board_public_files']=matches
    stage()
    report['transport']='Original Actions staging ZIP, all bytes hashed in runner; selected asset SHA/size match recovered private release. No private release download claim.'
    report['stage_id']=14731227846
    out=Path('sanitized-r10');out.mkdir(mode=0o700)
    for n,data in [('solver-status',st),('extended_states',es),('receipt.json',(json.dumps(report,sort_keys=True,indent=2)+'\n').encode())]:
        with (out/n).open('xb') as fp:fp.write(data)
    print('R10_SOLVER_STATE=PASS',report['installed'],report['apt_markers'],len(matches),flush=True)

RAW_SIZE = 20 * 1024**3

NAME = 'TB321FU-kubuntu2604-arm64-rootfs.img'

ARCHIVE_LIMIT = 16 * 1024**3

def checked_sha(value):
    need(isinstance(value, str) and re.fullmatch(r'[a-f0-9]{64}', value), 'invalid SHA-256')

def bounded(cmd, limit, consume, work, seconds):
    # timeout owns its process group; it also covers a stalled pipe read. Use
    # -so only, never extract an archive member to a filesystem path.
    def limits():
        resource.setrlimit(resource.RLIMIT_AS, (1024**3, 1024**3))
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    env = {'PATH': '/usr/bin:/bin', 'LANG': 'C', 'LC_ALL': 'C', 'HOME': str(work), 'TMPDIR': str(work)}
    proc = sp.Popen(['/usr/bin/timeout', '-k', '3', str(seconds), '/usr/bin/7z', *cmd],
                    cwd=work, env=env, stdin=sp.DEVNULL, stderr=sp.DEVNULL, stdout=sp.PIPE,
                    preexec_fn=limits, start_new_session=True)
    count = 0
    started = reported = time.monotonic()
    try:
        with proc.stdout as src:
            while block := src.read(1024**2):
                count += len(block)
                need(count <= limit, '7z output over declared limit')
                consume(block)
                now = time.monotonic()
                if limit >= 1024**3 and now - reported >= 30:
                    print(f'Rootfs raw SHA-256: {count/1024**3:.2f}/{limit/1024**3:.2f} GiB '
                          f'({count/1024**2/(now-started):.1f} MiB/s)', file=sys.stderr, flush=True)
                    reported = now
        need(proc.wait(timeout=8) == 0, '7z rejected archive or timed out')
    finally:
        if proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait(timeout=8)
    return count

def identity(path):
    st = path.lstat()
    need(stat.S_ISREG(st.st_mode), 'archive is not a regular file')
    return st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns

def _verify_raw(archive, expected, raw_size):
    # Lower sizes are an internal local test fixture only; all public entry
    # points use the pinned, independently checked product image size.
    checked_sha(expected)
    before = identity(archive)
    need(0 < before[2] <= ARCHIVE_LIMIT and 0 < raw_size <= RAW_SIZE, 'invalid archive or raw size')
    listing = bytearray()
    bounded(['l', '-ba', '-slt', '-t7z', '--', str(archive)], 16384, listing.extend, archive.parent, 45)
    fields = {}
    for line in bytes(listing).decode('ascii').strip().splitlines():
        k, sep, v = line.partition(' = ')
        need(sep and k and k not in fields, 'not exactly one listed member')
        fields[k] = v
    member = fields.get('Path')
    need(member in (NAME, 'out/ci-rootfs/' + NAME) and fields.get('Size') == str(raw_size)
         and fields.get('Encrypted') == '-' and re.fullmatch(r'[A-Z_ ]*-[rwx-]{9}', fields.get('Attributes', '')),
         'unexpected member path, type, encryption or data size')
    dig = hashlib.sha256()
    n = bounded(['x', '-so', '-bd', '-bb0', '-mmt=1', '-t7z', '--', str(archive), member],
                raw_size, dig.update, archive.parent, 3600)
    need(n == raw_size and dig.hexdigest() == expected, 'decoded rootfs size or SHA-256 differs')
    need(identity(archive) == before, 'archive changed during verification')
    return dict(member=member, raw_size=n, raw_sha256=dig.hexdigest())

R=dict(ARCHIVE_LIMIT=ARCHIVE_LIMIT,NAME=NAME,RAW_SIZE=RAW_SIZE,bounded=bounded)
def u16(data,i):return struct.unpack_from('<H',data,i)[0]

def u32(data,i):return struct.unpack_from('<I',data,i)[0]

class Ext:
    def __init__(self,v):
        self.v=v;s=v.read(1024,1024)
        need(u16(s,56)==0xef53 and (1024<<u32(s,24))==4096 and not u32(s,96)&0x10,'unknown ext4 geometry')
        self.bs=4096;self.ipg=u32(s,40);self.iz=u16(s,88);self.dz=u16(s,254)
        need(self.ipg and self.iz==256 and self.dz==64,'unknown inode/descriptor geometry')
    def inode(self,ino):
        need(0<ino<=2_000_000,'inode outside bounded source')
        gi,ix=divmod(ino-1,self.ipg);desc=self.v.read(self.bs+gi*self.dz,self.dz)
        table=u32(desc,8)+(u32(desc,40)<<32);node=self.v.read(table*self.bs+ix*self.iz,self.iz)
        need(u32(node,32)&0x80000,'not extent-mapped')
        size=u32(node,4)+(u32(node,108)<<32)
        return u16(node,0),size,node[40:100]
    def pieces(self,header,depth=None):
        magic,count,maxlen,level=struct.unpack_from('<4H',header)
        need(magic==0xf30a and 0<count<=maxlen<400 and level<=3 and (depth is None or level==depth) and
             12+12*count<=len(header),'invalid extent tree')
        for i in range(count):
            p=12+i*12
            if level:
                child=u32(header,p+4)+(u16(header,p+8)<<32)
                yield from self.pieces(self.v.read(child*self.bs,self.bs),level-1)
            else:
                n=u16(header,p+4);need(0<n<=32768,'uninitialized extent')
                yield u32(header,p),n,(u16(header,p+6)<<32)+u32(header,p+8)
    def data(self,ino,directory):
        mode,size,tree=self.inode(ino)
        need(mode>>12==(4 if directory else 8) and 0<size<=(1<<20 if directory else 3<<20),'wrong regular/directory layout')
        data=bytearray()
        for block,n,off in self.pieces(tree):
            need(len(data)==block*self.bs and len(data)<size,'hole, extra or reordered extents')
            data.extend(self.v.read(off*self.bs,min(n*self.bs,size-len(data))))
        need(len(data)==size,'incomplete extent map')
        return data
    def status(self):
        ino=2;chain=[]
        for name in (b'var',b'lib',b'dpkg',b'status'):
            data=self.data(ino,True);found=[];pos=0
            while pos<len(data):
                child,length,n,kind=struct.unpack_from('<IHBB',data,pos)
                need(length>=8 and length%4==0 and length<=self.bs-pos%self.bs and n<=length-8,'invalid directory record')
                if child and data[pos+8:pos+8+n]==name:
                    need(kind==(1 if name==b'status' else 2),'unexpected target type');found.append(child)
                pos+=length
            need(len(found)==1,'missing or multiple package database path entries')
            ino=found[0];chain.append(ino)
        data=self.data(ino,False);need(len(data)==2056727,'status size differs from June manifest')
        return bytes(data),chain

E=Ext
def archive_fields(path, proof):
    out = bytearray()
    R['bounded'](['l','-ba','-slt','-t7z','--',str(path)], 16384, out.extend, path.parent, 45)
    d = {}
    for row in out.decode('ascii').strip().splitlines():
        k, sep, val = row.partition(' = ')
        need(sep and k and k not in d,'unsupported multiple members or listing')
        d[k] = val
    method = re.fullmatch(r'LZMA2:(2[2-7])',d.get('Method',''))
    need(d.get('Path') == proof['member'] and proof['member'] in (R['NAME'],'out/ci-rootfs/'+R['NAME']) and
         d.get('Size') == str(proof['raw_size']) and 0 < proof['raw_size'] <= R['RAW_SIZE'] and
         d.get('Encrypted') == '-' and d.get('Block') == '0' and method and
         re.fullmatch(r'[A-Z_ ]*-[rwx-]{9}',d.get('Attributes','')) and
         re.fullmatch(r'[0-9]{1,11}',d.get('Packed Size','')), 'unsupported single member/coder/profile')
    return int(d['Packed Size']), 1 << int(method[1])

class Stream:
    def __init__(self, mm, pack, dictionary, length):
        self.mm, self.dictionary, self.length = mm, dictionary, length
        stop = 32 + pack
        v = mm[:32]
        need(len(v)==32 and v[:7] == b'7z\xbc\xaf\x27\x1c\x00' and
             zlib.crc32(v[12:32])==int.from_bytes(v[8:12],'little'), 'invalid standard 7z start header')
        nextoff,n,crc=struct.unpack_from('<QQI',v,12)
        need(0<pack<=R['ARCHIVE_LIMIT'] and stop<=32+nextoff and 0<=nextoff-pack<=65536 and
             0<n<=65536 and 32+nextoff+n==len(mm) and zlib.crc32(mm[32+nextoff:])==crc, 'unsupported 7z data/header arrangement')
        self.positions, self.raw, self.cache = [], [], []
        p, logical, chunks = 32, 0, 0
        while p < stop:
            c = mm[p]
            if c == 0:
                break
            if c == 1 or c >= 224:
                self.positions.append(p); self.raw.append(logical)
            need(len(self.raw)<=8192 and chunks < 1_000_000, 'too many LZMA2 chunks')
            chunks += 1
            if c in (1,2):
                need(p+3<=stop,'short LZMA2 chunk')
                n=int.from_bytes(mm[p+1:p+3],'big')+1
                p+=3+n
            else:
                need(c>=128 and p+5<=stop,'unsupported LZMA2 chunk')
                n=((c&31)<<16)+int.from_bytes(mm[p+1:p+3],'big')+1
                p+=5+(c>=192)+int.from_bytes(mm[p+3:p+5],'big')+1
            logical+=n
            need(p<=stop and logical<=length,'LZMA2 limits exceeded')
        need(p+1==stop and mm[p]==0 and logical==length and self.raw and self.raw[0]==0,
             'not one contiguous LZMA2 logical image at standard data position')
        self.raw.append(logical); self.positions.append(p+1)
        self.seeks = self.decoded = 0
        self.end = time.monotonic()+360

    def read(self,off,n):
        need(0<n<=4<<20 and 0<=off<=self.length-n,'out-of-range small read')
        for start,data in self.cache:
            if start<=off and off+n<=start+len(data):
                return data[off-start:off-start+n]
        i=bisect.bisect_right(self.raw,off)-1
        if off+n>self.raw[i+1]:
            m=self.raw[i+1]-off
            return self.read(off,m)+self.read(off+m,n-m)
        # Cache a short ordinary metadata/read-ahead window, never store a
        # dictionary reset segment or expose unrequested filesystem payload.
        window=min(self.raw[i+1]-off, max(n,128<<10))
        skip=off-self.raw[i]
        self.seeks+=1; self.decoded+=skip+window
        need(skip<=512<<20 and self.decoded<=12<<30 and self.seeks<=256, 'unsupported access cost for indexed read')
        dec=lzma.LZMADecompressor(format=lzma.FORMAT_RAW, filters=[{'id':lzma.FILTER_LZMA2,'dict_size':self.dictionary}])
        at=self.positions[i]; data=bytearray()
        while skip or len(data)<window:
            need(time.monotonic()<=self.end,'selective read exceeded time bound')
            part=b''
            if dec.needs_input:
                end=min(at+(128<<10),self.positions[i+1]);need(end>at,'short compressed input')
                part=self.mm[at:end];at=end
            x=dec.decompress(part,max_length=min(skip,1<<20) if skip else window-len(data))
            if skip: skip-=len(x)
            else: data.extend(x)
        got=bytes(data); self.cache.insert(0,(off,got)); del self.cache[10:]
        return got[:n]

class Files(E):
    def __init__(self,io):
        super().__init__(io)
        self.dirs={}

    def data(self,ino,directory):
        # mkfs.ext4 -d legitimately omits all-zero blocks in real ELF files.
        # Interpret such ordinary holes as the kernel/debugfs does. For a
        # directory we deliberately require every declared byte to be stored.
        mode,size,tree=self.inode(ino)
        need(mode>>12==(4 if directory else 8) and 0<size<=(1<<20 if directory else 3<<20),'unsupported selected inode layout')
        data=bytearray(size); end=0
        for block,n,physical in self.pieces(tree):
            start=block*self.bs; length=min(n*self.bs,size-start)
            need(end<=start<size and length>0 and (not directory or start==end),'overlap or unsupported directory hole')
            data[start:start+length]=self.v.read(physical*self.bs,length)
            end=start+length
        need(not directory or end==size,'missing tail of directory')
        return data

    def leaf(self,path):
        ino=2
        for i,name in enumerate(path.split('/')):
            if ino not in self.dirs:
                buf=self.data(ino,True); pos=0; entries={}
                while pos < len(buf):
                    j,n,l,k=struct.unpack_from('<IHBB',buf,pos)
                    need(n>=8 and n%4==0 and n<=self.bs-pos%self.bs and l<=n-8,'invalid ext4 dirent')
                    if j:
                        key=bytes(buf[pos+8:pos+8+l]);need(key not in entries,'duplicate directory child')
                        entries[key]=(j,k)
                    pos+=n
                self.dirs[ino]=entries
            item=self.dirs[ino].get(name.encode())
            need(item and item[1]==(1 if i+1==len(path.split('/')) else 2),'missing/non-direct selected path: '+path)
            ino=item[0]
        return ino
def children(ext,ino,wanted):
    data=ext.data(ino,True);p=0;seen={}
    while p<len(data):
        n,sz,k,kind=struct.unpack_from('<IHBB',data,p)
        need(sz>=8 and sz%4==0 and sz<=ext.bs-p%ext.bs and k<=sz-8,'unexpected dirent')
        name=bytes(data[p+8:p+8+k])
        if n and name in wanted:
            need(name not in seen and kind==wanted[name],'duplicate or wrong child')
            seen[name]=n
        p+=sz
    need(seen.keys()==wanted.keys(),'missing metadata sheet or its directory')
    return seen

J={'o':{'u16':u16,'u32':u32},'m':{'children':children}}
SPECS = {'usr/local/share/fonts': ('staff', 0o2775), 'usr/share/ppd/custom': ('lpadmin', 0o3775)}

def group_ids(raw):
    need(0 < len(raw) <= 1 << 20 and b'\0' not in raw, 'invalid group database')
    counts = collections.Counter()
    wanted = {name.encode('ascii') for name, _ in SPECS.values()}
    found = {}
    for row in raw.split(b'\n'):
        if not row or row.startswith(b'#'):
            continue
        fields = row.split(b':', 3)
        need(len(fields) == 4 and fields[0] and b':' not in fields[3] and
             re.fullmatch(rb'(?:0|[1-9][0-9]{0,9})', fields[2]), 'invalid group row')
        gid = int(fields[2])
        need(gid < 2**32 - 1, 'invalid numeric group id')
        counts[gid] += 1
        if fields[0] in wanted:
            need(fields[0] not in found and gid > 0, 'ambiguous target group name')
            found[fields[0]] = gid
    need(found.keys() == wanted and all(counts[g] == 1 for g in found.values()), 'missing or aliased target group')
    return {name.decode('ascii'): gid for name, gid in found.items()}

def descriptor(fs, ino):
    need(0 < ino <= 2_000_000, 'invalid inode')
    u16, u32 = J['o']['u16'], J['o']['u32']
    group, ix = divmod(ino - 1, fs.ipg)
    desc = fs.v.read(fs.bs + group * fs.dz, fs.dz)
    table = u32(desc, 8) + (u32(desc, 40) << 32)
    node = fs.v.read(table * fs.bs + ix * fs.iz, fs.iz)
    return (u16(node, 0), u16(node, 2) + (u16(node, 120) << 16),
            u16(node, 24) + (u16(node, 122) << 16))

def child(fs, parent, name, kind):
    return J['m']['children'](fs, parent, {name: kind})[name]

def inspect(fs):
    group = child(fs, child(fs, 2, b'etc', 2), b'group', 1)
    mode, uid, _ = descriptor(fs, group)
    need(stat.S_ISREG(mode) and uid == 0 and not mode & 0o022, 'untrusted group database')
    _, length, _ = fs.inode(group)
    need(0 < length <= 1 << 20, 'unexpected group database length')
    gids = group_ids(bytes(fs.data(group, False)))
    result = {}
    for path, (name, stock) in SPECS.items():
        ino = 2
        for part in path.split('/'):
            ino = child(fs, ino, part.encode('ascii'), 2)
        mode, uid, gid = descriptor(fs, ino)
        perms = stat.S_IMODE(mode)
        need(stat.S_ISDIR(mode) and uid == 0 and gid == gids[name],
             'wrong inode type, owner or image group: ' + path)
        # The producer permits writable tracked exceptions only in native mode.
        # A non-group-/non-world-writable tightening may only remove bits;
        # group-write with removed sticky/setgid safeguards is not a tightening.
        need(not perms & ~stock and (not perms & 0o022 or perms == stock),
             'unexpected directory permissions: ' + path)
        result[path] = dict(inode=ino, type='directory', uid=uid, gid=gid,
                            target_group=name, mode=f'{perms:04o}')
    return result

EXPECTED_ASSETS={'APT-BOOTSTRAP.tsv': [777309647, 16525, 'sha256:a2a2207b20fa1b6723090129c7ccf0bfe957df0e8a4d657cab9f95238e5c230a'], 'APT-PROVENANCE.tsv': [777309661, 2153379, 'sha256:331cbb10306526f3cc8e1307aa9a9455982dba441cb8ff832e5a72a8c07de44e'], 'APT-SOURCES.txt': [777309671, 935, 'sha256:6f31cdf2a4d90b725c420d3c4a02abd1e1d6ff128b6af4b2be59cb543c811218'], 'BUILD-PARAMETERS.md': [777309689, 7468, 'sha256:1ec3dcc945b3d89090f1fbb6dae54228f32b37f79c2452461fdb56f1eba584c1'], 'CAMERA-BUILD-REPORT.txt': [777309700, 16644, 'sha256:386d86abec12da481ef24029c7597b503bf3c67f49a5f8fb49ea3623c9b98910'], 'CAMERA-HANDOFF.tsv': [777309727, 1363, 'sha256:acf292688a20a90a2156528820bec42eb4a12b5faaa0961140b563785c9b3dfd'], 'HAPTICS-BUILD-TOOLS.tsv': [777309745, 10351, 'sha256:fec98c3d7276f2559f1e5584fe66efc632b023bef5ad7aa059aa70efec1c812a'], 'HAPTICS-SOURCE-LOCK.tsv': [777309764, 1697, 'sha256:8314dc331ff50a1dd00122344b1d090ab0b7f0fd98aa9c0e658ea36d73fa6f09'], 'KBUILD-FLAGS.tsv': [777309783, 2041, 'sha256:2d825902a4e387740010d2f3004fee4d476afb7322a3867948dc6cff21822df1'], 'KERNEL-BUNDLE.tsv': [777309799, 1321, 'sha256:3e12149ff2e1c99abefec913676cf71560ef0537c5d21397428c8cdec8d730cb'], 'KERNEL-SDK-MANIFEST.tsv': [777309810, 4450623, 'sha256:2effaf4994661a07e0a006217de632197d2e5205f3a3c3dc4a5d19cfda0f55a9'], 'KERNEL-SOURCE-LOCK.tsv': [777309827, 2422, 'sha256:44dd759df2311ad61e44103d0f148351033ba4ee3ea0a00050a567fe6f1946c4'], 'KERNEL-TOOLCHAIN.tsv': [777309836, 9442, 'sha256:38f74b9a730233f49d5b882a3dd5f4ec2f0ad9efe78563e92f5b45283c58d8e8'], 'MODULES.sha256': [777309852, 237301, 'sha256:db9573b965bdc8652815d56522353e33ea4123ac5f93be019f0b83209eec90de'], 'ROOTFS-PACKAGES.tsv': [777309882, 78664, 'sha256:8a2fc8f620605c32de36599559b156fd3b2785487ed49caebd745544c64e0f7c'], 'SENSOR-SOURCE-LOCK.tsv': [777309912, 543, 'sha256:e019ac6c4e073ae372b7b874740d1066439fbf1e98c70bfb6e7aaaeb707eeb9c'], 'SHA256SUMS-tb321fu-camera-stack-debs.txt': [777309939, 108, 'sha256:ccc925c5b47e9d57a5787b856cb7010912c7ed25dfcea4d07efd0789210a934a'], 'SHA256SUMS.txt': [777309956, 2092, 'sha256:a94bf36c6f6c12dc295cc942a07a7ee5a6463cfd13e1c3f1977184892338944d'], 'VERIFIED-BUNDLE.tsv': [777309976, 1705, 'sha256:475a0ae0d7a0e50faf039e40e09de8052d78435f557399970055a572ed6c4aa1'], 'VERIFIED-INPUTS.tsv': [777309999, 1963, 'sha256:2ad06e9389fc3255c246d3e6a4e0a670923055fec7cccb1a01af405e3200acb2'], 'boot.img.7z': [777310018, 2429060, 'sha256:a9c2e176b34d3205f8f71b5819c58d215dcb993395191d8d44f37d922f592b02'], 'grub.img.7z': [777310050, 15007001, 'sha256:7c5997d2db5905ce84a5e22c8c93ef433ef98d35337c9b1bae72523d5953e562'], 'rootfs.img.7z.000': [783084609, 1992294400, 'sha256:be226b5c3bba7917dd3c1384b251210787ce0ce1517b367fe9985eba855a3fe0'], 'rootfs.img.7z.001': [783086522, 1279272401, 'sha256:f4d7072e2fa75311732f6cb0f7c90ce996d6256dbb415c72842463dcceb86591'], 'tb321fu-camera-stack_20261122.1_arm64.deb': [783084462, 848290, 'sha256:803068f41884475af7f73db36079d8076ba04ae38931121a1dce54a8c182329b']}
PUBLIC_FILES={'opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so': (420, '00de6141eed6c333f8ce40df27c97748897d64e6fd12058712dc643875cf3ad8'), 'opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera.so.0.7.1': (420, '3b97d807a08ebb6139f78e326ce48db40c4dcb248a4ddf83c711e4d52c5fb91d'), 'opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so': (420, 'e49f2d9ac1659379d4501cfcb4666ff363e9e64dda7acae6b9fe619a0e3b183d'), 'opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so.sign': (420, '458b8cf6da41d623ce44e6f0b1aed7138b16cfdf04a7e2ddb39c67d10acc0f97'), 'usr/lib/firmware/qcom/gen70900_aqe.fw': (420, '25237c161d727b8ea92b4beb837a31651b44ea78bfc34d95672af8f346a45825'), 'usr/lib/firmware/qcom/gen70900_sqe.fw': (420, 'a739a1ef14e4418c5a1f1e1da444deb71aeeb4a31370ab41a4dddf378ab5683d'), 'usr/lib/firmware/qcom/gmu_gen70900.bin': (420, '9685f62c42543befcaee68d25355e16bf55cdb0d573bddcc9f6633f59eec3f72'), 'usr/lib/firmware/qcom/vpu/vpu33_p4.mbn': (420, '8166b1fde9725547bd07eba4add22f442dc938f17274fbf358dbdcfc88ec5f31'), 'usr/share/alsa/ucm2/LenovoY700TB321/HiFi.conf': (420, 'f4b18b4bc915641312eb06070cc076effe155cad7a990beb96a59777022ca552'), 'usr/share/alsa/ucm2/LenovoY700TB321/LenovoY700TB321.conf': (420, '541dfaa6c01f8e0bd01760cfeae0b8d2dc1394b3290aac68ee4dea2cbd3e6ed1'), 'usr/share/alsa/ucm2/LenovoY700TB321/wcd939x/HeadphoneDisableSeq.conf': (420, 'd5a5a18cfefb510c0e66eeb17d4cd70a0a905706cd65f0f264698663703b58fb'), 'usr/share/alsa/ucm2/LenovoY700TB321/wcd939x/HeadphoneEnableSeq.conf': (420, '333c56a133d260f696fbc817dfb7760e7c75619d0540bf62128527dd9a7438f5'), 'usr/share/alsa/ucm2/LenovoY700TB321/wcd939x/HeadphoneMicDisableSeq.conf': (420, 'e19abbbf3f982aa75b539a5f4818d0a2fdcde030e394e956b37769bbc00db25a'), 'usr/share/alsa/ucm2/LenovoY700TB321/wcd939x/HeadphoneMicEnableSeq.conf': (420, '2c179e5eca5e6d88b8d920a146745e970fde0a4ec60d38b77331081023de0ccb')}
if __name__=='__main__':main()
