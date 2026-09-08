#!/usr/bin/env python3
"""Local, synthetic end-to-end search evaluation. No provider requests.

Use --model-root with the already-downloaded text-e5-small revision directory.
The optional --scale phase indexes 1,000 synthetic recordings / 10,000 passages.
Results report measured quality, not acceptance assertions about model accuracy.
"""
import argparse, json, os, pathlib, plistlib, shutil, sqlite3, statistics, subprocess, tempfile, time
P = [
 "We are hiring a software developer for the Atlas project.",
 "Alice prefers short written follow-ups instead of phone calls.",
 "O lançamento foi adiado porque o fornecedor ainda não entregou as peças.",
 "Ben werkt sinds januari als ontwerper bij Northstar.",
 "We cannot hire anyone until the budget is approved.",
 "The cat is sleeping on the sofa next to the window.",
 "A reunião com a equipa de vendas será na sexta-feira.",
 "De klant heeft de factuur nog niet betaald.",
 "The forecast predicts heavy rain throughout the weekend.",
 "I handed leadership of Atlas to Priya on 2026-02-12."]
Q = [("finding new staff",0),("quem está a recrutar programadores?",0),
 ("wie zoekt een softwareontwikkelaar?",0),("how should I follow up with Alice?",1),
 ("como prefere a Alice receber mensagens?",1),("why was the launch delayed?",2),
 ("waarom is de lancering uitgesteld?",2),("where does Ben work?",3),
 ("o que impede novas contratações?",4),("when is the sales meeting?",6),
 ("unpaid customer invoice",7),("who took over the project?",9),
 ("Atlas handover para Priya",9),("Northstar ontwerper job",3),("factuur do cliente unpaid",7)]
a=argparse.ArgumentParser();a.add_argument("--model-root",required=True);a.add_argument("--scale",action="store_true");a.add_argument("--output",default="/tmp/listen-context-benchmark.json");args=a.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1]
root=pathlib.Path(tempfile.mkdtemp(prefix="listen-search-benchmark-"));app=root/"Benchmark.app";library=root/"library"
subprocess.run(["cp","-cR",str(repo/"Listen.app"),str(app)],check=True)
info=app/"Contents/Info.plist";p=plistlib.loads(info.read_bytes());domain="com.mgo.listen-search-benchmark-"+root.name.rsplit("-",1)[1];p["CFBundleIdentifier"]=domain;info.write_bytes(plistlib.dumps(p))
subprocess.run(["codesign","--force","--sign","-","--deep",str(app)],check=True,capture_output=True)
model=pathlib.Path(args.model_root);target=library/"models/text-e5-small"/model.name;target.parent.mkdir(parents=True)
subprocess.run(["cp","-cR",str(model),str(target)],check=True)
subprocess.run(["defaults","write",domain,"multilingualSearch","-bool","true"],check=True)
env=dict(os.environ,LISTEN_LIBRARY=str(library),LISTEN_NO_KEYCHAIN="1",LISTEN_NO_TELEMETRY="1",SHELL="/usr/bin/false")
binary=app/"Contents/MacOS/Listen"
def rec(rid,texts):
 d=library/"recordings"/rid;d.mkdir(parents=True,exist_ok=True)
 turns=[dict(start=i*10,end=(i+1)*10,speaker="Benchmark Person",text=t) for i,t in enumerate(texts)]
 for filename,value in [("metadata.json",dict(id=rid,title="Synthetic conversation "+rid,recorded_at="2026-09-01T10:00:00Z",duration=len(turns)*10,source="imported",state="done")),("turns.json",turns),("transcript.json",dict(segments=turns,duration=len(turns)*10,model="synthetic",wordLevel=False,cleanup={},dictionary={}))]:
  (d/filename).write_text(json.dumps(value))
def index():
 start=time.perf_counter();r=subprocess.run([str(binary),"context","index"],env=env,capture_output=True,text=True,timeout=900)
 if r.returncode: raise RuntimeError(r.stderr)
 return (time.perf_counter()-start)*1000
class Client:
 def __init__(self):
  self.log=(root/"mcp.log").open("a");self.p=subprocess.Popen([str(binary),"mcp"],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.log,text=True);self.i=0
 def search(self,q):
  self.i+=1;request=dict(jsonrpc="2.0",id=self.i,method="tools/call",params=dict(name="search_context",arguments=dict(query=q,limit=3)))
  start=time.perf_counter();self.p.stdin.write(json.dumps(request)+"\n");self.p.stdin.flush()
  line=self.p.stdout.readline()
  if not line: raise RuntimeError("MCP exited before returning search")
  result=json.loads(line)["result"]
  if result.get("isError"): raise RuntimeError(result)
  return json.loads(result["content"][0]["text"]),(time.perf_counter()-start)*1000
 def close(self): self.p.stdin.close();self.p.wait(timeout=30);self.log.close()
for i,p in enumerate(P):rec("sample-"+str(i),[p])
report=dict(model=model.name,fixture=str(root),smallIndexMS=index(),rows=[])
c=Client()
for q,wanted in Q:
 result,elapsed=c.search(q);ids=[m["evidence"][0]["source"] for m in result["matches"]];expected="rec:sample-"+str(wanted)
 report["rows"].append(dict(query=q,expected=expected,rank=ids.index(expected)+1 if expected in ids else None,results=ids,mode=result["mode"],elapsedMS=elapsed))
c.close()
report["top1"]=sum(r["rank"]==1 for r in report["rows"])/len(Q)
report["recallAt3"]=sum(r["rank"] is not None for r in report["rows"])/len(Q)
report["warmMedianMS"]=statistics.median(r["elapsedMS"] for r in report["rows"][1:])
if args.scale:
 for i in range(1000):rec("scale-"+str(i),P)
 report["largeIndexMS"]=index();c=Client();timings=[]
 for q,_ in Q[:8]:
  result,elapsed=c.search(q);timings.append(elapsed)
 c.close();report["largeSources"]=result["indexedSources"];report["largeEntries"]=sqlite3.connect(library/"context/memory.sqlite").execute("select count(*) from search").fetchone()[0];report["largeQueryMS"]=timings;report["largeWarmMedianMS"]=statistics.median(timings[1:])
pathlib.Path(args.output).write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k!="rows"},indent=2))
subprocess.run(["defaults","delete",domain],capture_output=True)
