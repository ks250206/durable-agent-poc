@testable import AgentRuntime
import ChatCore
import Foundation
import Testing
import Darwin

/// Runs a real subprocess with isolated files; never starts an installed app-server or opens CLI credentials.
struct CodexFixture: Sendable {
    let root: URL
    var executable: URL { root.appendingPathComponent("codex") }
    var storage: URL { root.appendingPathComponent("storage") }
    let model = ModelSelection(account: CodexProviderSettingsService.account, modelID: "fixture-model")
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("DurableChat-Codex-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(Self.script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data(codexProtocolSchemas.utf8).write(to: root.appendingPathComponent("schemas.json"))
        try Data("fixture-auth-sentinel".utf8).write(to: root.appendingPathComponent("auth-state"))
    }
    func settings(timeout: TimeInterval = 5) async throws -> CodexProviderSettingsService {
        let service = try CodexProviderSettingsService(storageDirectory: storage, requestTimeout: timeout)
        try await service.update(ProviderConfiguration(account: model.account, selectedModelID: model.modelID, executablePath: executable.path))
        return service
    }
    func backend(settings: CodexProviderSettingsService, timeout: TimeInterval = 5) throws -> CodexChatBackend {
        try CodexChatBackend(storageDirectory: storage, settings: settings, requestTimeout: timeout, turnTimeout: timeout * 4)
    }
    func marker(_ value: String, name: String = "mode") throws { try Data(value.utf8).write(to: root.appendingPathComponent(name)) }
    func calls(_ method: String? = nil) throws -> [[String: Any]] {
        let url = root.appendingPathComponent("calls")
        if !FileManager.default.fileExists(atPath: url.path) { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }.filter { method == nil || $0["method"] as? String == method }
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    static let script = #"""
#!/usr/bin/python3
import json,sys,os,pathlib,time,subprocess
root=pathlib.Path(__file__).parent
schemas=json.loads((root/'schemas.json').read_text())
def mode(): return (root/'mode').read_text() if (root/'mode').exists() else ''
def log(o):
 with (root/'calls').open('a') as f: f.write(json.dumps(o)+'\n')
def emit(o): print(json.dumps(o),flush=True)
def validate(v,s,top):
 if s is True:return True
 if s is False:return False
 if '$ref' in s:return validate(v,top['definitions'][s['$ref'].split('/')[-1]],top)
 if 'allOf' in s and not all(validate(v,x,top) for x in s['allOf']):return False
 if 'anyOf' in s and not any(validate(v,x,top) for x in s['anyOf']):return False
 if 'oneOf' in s and sum(validate(v,x,top) for x in s['oneOf'])!=1:return False
 if 'enum' in s and v not in s['enum']:return False
 ts=s.get('type');ts=[ts] if isinstance(ts,str) else ts
 types={'object':isinstance(v,dict),'array':isinstance(v,list),'string':isinstance(v,str),'integer':type(v)==int,'number':type(v) in (int,float),'boolean':type(v)==bool,'null':v is None}
 if ts and not any(types[t] for t in ts):return False
 if isinstance(v,dict):
  if any(k not in v for k in s.get('required',[])):return False
  props=s.get('properties',{})
  if not all(validate(x,props[k],top) for k,x in v.items() if k in props):return False
  extra=s.get('additionalProperties',True)
  if not all(validate(x,extra,top) for k,x in v.items() if k not in props):return False
 if isinstance(v,list) and 'items' in s and not all(validate(x,s['items'],top) for x in v):return False
 return True
def reply(req,result):
 responseSchemas={'initialize':'InitializeResponse','model/list':'ModelListResponse','thread/start':'ThreadStartResponse','thread/resume':'ThreadResumeResponse','turn/start':'TurnStartResponse'}
 if req['method'] in responseSchemas:
  assert validate(result,schemas[responseSchemas[req['method']]],schemas), 'Invalid response fixture'
 emit({'id':req['id'],'result':result})
def notify(method,params):
 name={'item/agentMessage/delta':'AgentMessageDeltaNotification','item/completed':'ItemCompletedNotification','turn/completed':'TurnCompletedNotification'}[method]
 assert validate(params,schemas[name],schemas), 'Invalid notification fixture'
 emit({'method':method,'params':params})
def model(mid):return {'id':'catalog-'+mid,'model':mid,'displayName':mid,'description':'fixture','hidden':False,'isDefault':False,'defaultReasoningEffort':'medium','supportedReasoningEfforts':[]}
def turn(tid,status='inProgress',items=[]):return {'id':tid,'status':status,'items':items}
def item(i,text):return {'id':i,'type':'agentMessage','text':text}
def delta(thread,tid,i,text):notify('item/agentMessage/delta',{'threadId':thread,'turnId':tid,'itemId':i,'delta':text})
def done_item(thread,tid,i,text):notify('item/completed',{'threadId':thread,'turnId':tid,'item':item(i,text),'completedAtMs':1})
log({'method':'launch','argv':sys.argv[1:],'cwd':os.getcwd(),'env':list(os.environ.keys()),'pid':os.getpid()})
phase=0;active=None
mapping={'initialize':'InitializeParams','account/read':'GetAccountParams','model/list':'ModelListParams','thread/start':'ThreadStartParams','thread/resume':'ThreadResumeParams','turn/start':'TurnStartParams','turn/interrupt':'TurnInterruptParams'}
for line in sys.stdin:
 req=json.loads(line);log(req);m=req.get('method');p=req.get('params',{})
 if m is None:continue # client rejection of server requests
 if m=='initialized':
  assert phase==1;phase=2
  if mode()=='no-read':time.sleep(30)
  continue
 assert m=='initialize' and phase==0 or phase==2
 if m in mapping:
  s=schemas[mapping[m]]
  if not validate(p,s,schemas):
   log({'method':'schema-failure','request':m});sys.exit(31)
 if m=='initialize':
  phase=1
  if mode()=='timeout':time.sleep(30)
  if mode()=='orphan':
   c=subprocess.Popen(['/bin/sleep','30']);(root/'childpid').write_text(str(c.pid));sys.exit(0)
  if mode()=='malformed':print('{bad',flush=True);time.sleep(30)
  if mode()=='oversized':print('x'*(3*1024*1024),flush=True);time.sleep(30)
  if mode()=='exit':sys.exit(17)
  if mode()=='stderr':print('fake-sensitive-token',file=sys.stderr,flush=True);sys.exit(18)
  reply(req,{'userAgent':'fixture','platformFamily':'unix','platformOs':'macos','codexHome':str(root/'fake-codex-home')})
 elif m=='account/read':
  assert p['refreshToken'] is False
  if mode()=='preflight':
   (root/'probing').write_text('yes');time.sleep(30)
  auth=(root/'auth-kind').read_text() if (root/'auth-kind').exists() else 'chatgpt'
  a=None if auth=='signedout' else {'type':auth}
  if auth=='chatgpt':a.update(email=None,planType='free')
  reply(req,{'account':a,'requiresOpenaiAuth':True})
 elif m=='model/list':
  if p.get('cursor') is None:reply(req,{'data':[model('fixture-model')],'nextCursor':'page2'})
  else:reply(req,{'data':[model('fixture-model'),model('other')],'nextCursor':'page2' if mode()=='cursorloop' else None})
 elif m in ('thread/start','thread/resume'):
  assert p['cwd']==os.getcwd() and p['sandbox']=='read-only' and p['approvalPolicy']=='never'
  thread=p.get('threadId','thread-1')
  if m=='thread/resume':assert (root/'thread-state').read_text()==thread
  else:(root/'thread-state').write_text(thread)
  reply(req,{'thread':{'id':thread,'cliVersion':'0.167.0','createdAt':1,'updatedAt':1,'cwd':os.getcwd(),'ephemeral':False,'modelProvider':'openai','preview':'','projectId':None,'sessionId':'session-1','source':'appServer','status':{'type':'idle'},'turns':[]},'model':'fixture-model','cwd':os.getcwd(),'approvalPolicy':'never','approvalsReviewer':'user','modelProvider':'openai','sandbox':{'type':'workspaceWrite' if mode()=='unsafe' else 'readOnly','networkAccess':False}})
 elif m=='turn/start':
  assert p['sandboxPolicy']=={'type':'readOnly','networkAccess':False} and p['approvalPolicy']=='never'
  thread=p['threadId'];tid='turn-'+str(len(list(root.glob('turn-*'))));(root/tid).write_text('yes')
  active=(thread,tid)
  text=p['input'][0]['text']
  if text=='before-response':
   (root/'turnpending').write_text('yes');time.sleep(30)
  # Notification before response tests ordering and buffering.
  delta(thread,tid,'b' if text=='ordering' else 'a','Wor' if text=='ordering' else 'Hel')
  reply(req,{'turn':turn(tid)})
  if text in ('hang','approval','orphan-turn'):
   child=subprocess.Popen(['/bin/sleep','30']);(root/'childpid').write_text(str(child.pid))
   if text=='orphan-turn':sys.exit(0)
   if text=='approval':
    for i,meth in enumerate(['item/commandExecution/requestApproval','item/fileChange/requestApproval','item/permissions/requestApproval','item/tool/call','account/chatgptAuthTokens/refresh']):emit({'id':'server-'+str(i),'method':meth,'params':{'fakeSecret':'fake-sensitive-token'}})
   continue
  if text=='rpc-error':emit({'id':req['id'],'error':{'code':-1,'message':'fake-sensitive-token'}});notify('turn/completed',{'threadId':thread,'turn':turn(tid,'failed')});continue
  delta('unrelated',tid,'a','WRONG')
  delta(thread,'old-turn','a','WRONG')
  delta(thread,tid,'a','lo')
  delta(thread,tid,'a','lo') # identical deltas must not be guessed away; final item is authoritative
  done_item(thread,tid,'a','Hello')
  done_item(thread,tid,'a','Hello')
  delta(thread,tid,'a','LATE')
  done_item(thread,tid,'b','World')
  final=turn(tid,'completed',[item('a','Hello'),item('b','World')])
  notify('turn/completed',{'threadId':thread,'turn':final})
  notify('turn/completed',{'threadId':thread,'turn':final})
 elif m=='turn/interrupt':
  assert active==(p['threadId'],p['turnId'])
  reply(req,{})
  delta(p['threadId'],p['turnId'],'a','LATE AFTER STOP')
  notify('turn/completed',{'threadId':p['threadId'],'turn':turn(p['turnId'],'interrupted')})
 else:
  emit({'id':req['id'],'error':{'code':-32601,'message':'fake-sensitive-token'}})
"""#
}

func codexEventually(_ body: () async throws -> Bool) async throws {
    for _ in 0..<1200 {
        if try await body() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CodexRuntimeError.timedOut
}
func codexSettled(_ backend: CodexChatBackend, _ id: ConversationID) async throws -> ConversationSnapshot {
    try await codexEventually { try await backend.snapshot().loadedConversations.first { $0.id == id }?.activity.isBusy == false }
    return try #require(try await backend.snapshot().loadedConversations.first { $0.id == id })
}
