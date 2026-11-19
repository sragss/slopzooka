#!/usr/bin/env node
// Disposable protocol peer; independent effect log makes duplicate dispatch observable.
import http from 'node:http';
import fs from 'node:fs';
import { WebSocketServer } from 'ws';
if (!process.argv.includes('app-server')) {
  process.stdout.write('OWNED-TUI ' + process.argv.at(-1) + '\n');
  setInterval(()=>{},1000); process.stdin.resume();
} else {
  const socket=process.argv[process.argv.indexOf('--listen')+1].slice('unix://'.length);
  const server=http.createServer(), peers=new Set();
  const wss=new WebSocketServer({server});
  const thread={id:'11111111-1111-4111-8111-111111111111',status:{type:'idle'},turns:[]};
  let serial=0, active, pending=[], question, rejectResume=false;
  const log=x=>fs.appendFileSync('effects.jsonl',JSON.stringify(x)+'\n');
  log({event:'environment', terminalProgram:process.env.TERM_PROGRAM, inheritedTerminalIdentity:Boolean(process.env.ITERM_SESSION_ID || process.env.TERM_SESSION_ID)});
  const broadcast=(method,params)=>{for(const ws of peers)ws.send(JSON.stringify({method,params:{threadId:thread.id,...params}}));};
  function start(text,clientId){
    const turn={id:'turn-'+(++serial),status:'inProgress',items:[{type:'userMessage',clientId,text}]};
    thread.turns.push(turn);active=turn;thread.status={type:'active'};
    broadcast('turn/started',{turn});broadcast('item/completed',{turnId:turn.id,item:turn.items[0]});log({event:'start',text,clientId});
    if(text.includes('approval')) {
      question=99;for(const ws of peers)ws.send(JSON.stringify({id:99,method:'item/commandExecution/requestApproval',params:{threadId:thread.id,turnId:turn.id,command:'printf fixture',reason:'fixture'}}));
    } else if(!text.includes('hold'))setTimeout(()=>{if(text.includes('finish-offline'))for(const ws of peers)ws.terminate();finish(turn,'completed');},50);
    return turn;
  }
  function finish(turn,status){if(active!==turn)return;turn.status=status;const long=turn.items[0].text.includes('long-result');if(long)turn.items.push({type:'agentMessage',text:'Earlier progress, not the final answer.'});turn.items.push({type:'agentMessage',text:long?'Outcome: fixture passed.\n\n'+('supporting detail '.repeat(500)):'DONE '+turn.id});broadcast('item/completed',{turnId:turn.id,item:turn.items.at(-1)});active=undefined;thread.status={type:'idle'};log({event:'finish',turnId:turn.id});broadcast('turn/completed',{turn});if(status==='completed'&&pending.length){const p=pending.shift();start(p.text,p.clientUserMessageId);}}
  wss.on('connection',ws=>{peers.add(ws);ws.on('close',()=>peers.delete(ws));ws.on('message',raw=>{
    const m=JSON.parse(raw.toString()); const p=m.params??{};
    if(!m.method){if(m.id===question){log({event:'approval',decision:m.result?.decision});finish(active,m.result?.decision==='accept'?'completed':'interrupted');}return;}
    if(m.id===undefined)return;
    const reply=result=>ws.send(JSON.stringify({id:m.id,result}));
    if(m.method==='initialize')return reply({});
    if(m.method==='thread/resume'&&rejectResume){rejectResume=false;log({event:'resume-rejected'});return ws.send(JSON.stringify({id:m.id,error:{code:-1,message:'transient resume failure'}}));}
    if(m.method==='thread/start'||m.method==='thread/resume'||m.method==='thread/read')return reply({thread});
    if(m.method==='turn/start')return reply({turn:start(p.input[0].text,p.clientUserMessageId)});
    if(m.method==='thread/queue/list')return reply({data:pending,nextCursor:null});
    if(m.method==='thread/queue/add'){
      const entry={id:'queue-'+(++serial),clientUserMessageId:p.clientUserMessageId,text:p.input[0].text};pending.push(entry);log({event:'queue',request:p.clientUserMessageId});
      if(entry.text.includes('lose-reply')){rejectResume=entry.text.includes('reject-next-resume');ws.close();return;}
      return reply({queuedSubmission:entry});
    }
    if(m.method==='thread/queue/start'){if(active||!pending.length)return ws.send(JSON.stringify({id:m.id,error:{code:-1,message:'busy or empty'}}));const q=pending.shift();return reply({turn:start(q.text,q.clientUserMessageId)});}
    if(m.method==='thread/queue/delete'){pending=pending.filter(q=>q.id!==p.queuedSubmissionId);return reply({});}
    if(m.method==='turn/steer'){if(p.expectedTurnId!==active?.id)return ws.send(JSON.stringify({id:m.id,error:{code:-1,message:'stale'}}));log({event:'steer'});return reply({turnId:active.id});}
    if(m.method==='turn/interrupt'){reply({});if(active?.id===p.turnId)finish(active,'interrupted');return;}
    ws.send(JSON.stringify({id:m.id,error:{code:-32601,message:'unsupported'}}));
  });});server.listen(socket);
}
