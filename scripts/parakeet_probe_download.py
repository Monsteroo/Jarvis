"""Download pinned Core ML weights only; never reads or uploads audio."""
import json, pathlib, concurrent.futures, subprocess, hashlib
ROOT=pathlib.Path(__file__).resolve().parents[1]/'.runtime/parakeet-probe'
REVISION='5c4bcfaca501587beaedfd23b72a678bf7194de1'
REPO='ihnatov-yuri/parakeet-tdt-0.6b-v3-uk'
ROOT.mkdir(parents=True,exist_ok=True)
def fetch(url,target):
 subprocess.run(['curl','-L','--fail','--retry','2','-sS',url,'-o',str(target)],check=True)
treefile=ROOT/'model-tree.json'
if not treefile.exists():fetch(f'https://huggingface.co/api/models/{REPO}/tree/{REVISION}/coreml/int8/parakeet-tdt-0.6b-v3?recursive=true',treefile)
tree=json.loads(treefile.read_text());files=[x for x in tree if x['type']=='file']
def get(item):
 path=item['path'];target=ROOT/'model'/pathlib.Path(path).relative_to('coreml/int8');target.parent.mkdir(parents=True,exist_ok=True)
 if not target.exists() or target.stat().st_size!=item['size']:
  temp=target.with_name(target.name+'.download');fetch(f'https://huggingface.co/{REPO}/resolve/{REVISION}/{path}',temp);temp.replace(target)
 data=target.read_bytes();digest=hashlib.sha256(data).hexdigest()
 assert len(data)==item['size'],f'Size mismatch: {path}'
 if 'lfs' in item:assert digest==item['lfs']['oid'],f'SHA256 mismatch: {path}'
 else:assert hashlib.sha1(f'blob {len(data)}\0'.encode()+data).hexdigest()==item['oid'],f'Git blob mismatch: {path}'
 return {'path':str(target.relative_to(ROOT)),'sha256':digest,'size':len(data)}
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:manifest=list(pool.map(get,files))
(ROOT/'sha256-manifest.json').write_text(json.dumps({'repository':REPO,'revision':REVISION,'files':manifest},indent=2)+'\n')
print(f'Verified {len(manifest)} files; revision {REVISION}')
