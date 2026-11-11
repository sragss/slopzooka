import fs from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
const dir='/tmp/slz-preview-hardening';
const {run}=JSON.parse(await fs.readFile('/tmp/slz-preview-validation/current.json','utf8'));
const setup=JSON.parse(await fs.readFile(`${run}/setup.private.json`,'utf8'));
const response=await fetch(setup.base+'/api/frontends',{headers:{Authorization:`Bearer ${setup.token}`}});
const {windows}=await response.json();
const pick=test=>{const found=windows.sources.filter(test);if(found.length!==1)throw Error('Ambiguous fixture');return found[0].id;};
const mac=pick(s=>s.title==='Slz Native Preview Fixture');
const ios=pick(s=>s.application==='Simulator'&&s.title.includes('Slz Native Preview Validation'));
const pause=ms=>new Promise(r=>setTimeout(r,ms));
async function state(change){const file=run+'/fixture.json';const old=JSON.parse(await fs.readFile(file,'utf8'));await fs.writeFile(file+'.local',JSON.stringify({...old,...change}));await fs.rename(file+'.local',file);}
async function probe(name,sourceID,seconds,ackDelayMs=0){
 const config=dir+'/'+name+'.private.json';await fs.writeFile(config,JSON.stringify({base:setup.base,token:setup.token,sourceID,seconds,ackDelayMs}),{mode:0o600});
 const log=await fs.open(dir+'/'+name+'.jsonl','w',0o600);
 const child=spawn(dir+'/receiver',[config],{stdio:['ignore',log.fd,log.fd]});await log.close();
 const [code]=await once(child,'exit');
 const text=await fs.readFile(dir+'/'+name+'.jsonl','utf8');
 const summary=text.trim().split('\n').map(s=>JSON.parse(s)).findLast(s=>s.event==='summary');
 console.log(JSON.stringify({name,code,...summary}));
 if(code!==0||!summary||summary.decoded<10)throw Error(name+' failed');
 return summary;
}
try{
 await state({portrait:true,covered:true,staticImage:false});await pause(1000);
 await probe('mac-delayed-after',mac,20,80);
 await state({portrait:false,covered:false});await pause(1000);
 const results=Promise.all([probe('mac-cycle-after',mac,40),probe('ios-paired-after',ios,40)]);
 await pause(7000);await state({covered:true});
 await pause(6000);await state({portrait:true});
 await pause(7000);await state({staticImage:true});
 await pause(4000);await state({counter:5,nonce:'static-refresh'});
 await pause(4000);await state({staticImage:false});
 await pause(3000);await state({portrait:false});
 await pause(3000);await state({covered:false});
 const summaries=await results;
 if(summaries[0].formats.length<3)throw Error('Missing resize formats');
 console.log(JSON.stringify({event:'local-checks.passed',run}));
}finally{await state({portrait:false,covered:false,staticImage:false});}
