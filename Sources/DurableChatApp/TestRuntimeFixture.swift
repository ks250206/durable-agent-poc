import ChatCore
import Foundation

/// Available only via --test-runtime. Real temp SQLite/FauxProvider and clearly labeled local CLI fixtures.
/// No production credential service, sign-in, model call or user storage is used.
enum TestRuntimeFixture {
    private struct Archive: Encodable {
        var version = 1
        var selected: ConversationID?
        var conversations: [ConversationSnapshot]
        var sessions: [String: String] = [:]
        var accepted: [String: String] = [:]
    }
    static func prepareCursor(at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = #"""
        #!/bin/sh
        case "$1" in
          --help) echo 'Cursor --trust --print --mode ask --model --resume stream-json --stream-partial-output status login models' ;;
          status) echo '{"authenticated":true}' ;;
          models) echo 'simulated-cursor - SIMULATED Cursor fixture (no AI)' ;;
          login|logout) exit 0 ;;
          --print)
            /bin/cat >/dev/null
            echo '{"type":"assistant","timestamp_ms":1,"message":{"content":[{"type":"text","text":"SIMULATED Cursor response. No AI service was contacted. "}]}}'
            /bin/sleep 3
            echo '{"type":"result","subtype":"success","is_error":false,"result":"SIMULATED Cursor fixture response completed. No AI service was contacted."}'
            ;;
          *) exit 1 ;;
        esac
        """#
        let executable = root.appendingPathComponent("simulated-agent")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let id = ConversationID("cursor:conversation:simulated-history")
        let date = Date(timeIntervalSince1970: 0)
        let summary = ConversationSummary(id: id, title: "Simulated Cursor • minimap history", createdAt: date, updatedAt: date)
        let messages = (0..<48).map { index in
            ChatMessage(id: MessageID("cursor:fixture:\(index)"), conversationID: id,
                        role: index.isMultiple(of: 2) ? .user : .assistant,
                        content: "SIMULATED message \(index + 1). " + String(repeating: "This is local sample history for transcript and minimap checks. ", count: 4), createdAt: date)
        }
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("conversations.json").path) else { return }
        try JSONEncoder().encode(Archive(conversations: [ConversationSnapshot(summary: summary, messages: messages)]))
            .write(to: root.appendingPathComponent("conversations.json"), options: .atomic)
    }
    /// Implements only the local app-server surface used by the existing #19 adapter.
    /// Assertions fail closed if composition ever attempts a login/logout or a different executable mode.
    static func prepareCodex(at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("simulated-codex")
        try Data(codexScript.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    private static let codexScript = #"""
    #!/usr/bin/python3
    import json,sys,os,pathlib,subprocess,uuid
    root=pathlib.Path(__file__).parent
    assert 'app-server' in sys.argv and 'login' not in sys.argv and 'logout' not in sys.argv
    def log(o):
        with (root/'fixture-calls.jsonl').open('a') as f: f.write(json.dumps(o)+'\n')
    def emit(o): print(json.dumps(o),flush=True)
    def reply(req,result): emit({'id':req['id'],'result':result})
    def notify(method,params): emit({'method':method,'params':params})
    def marker(name,default=''): return (root/name).read_text() if (root/name).exists() else default
    def item(text): return {'id':'simulated-item','type':'agentMessage','text':text}
    log({'method':'launch','pid':os.getpid(),'cwd':os.getcwd()})
    active=None
    for line in sys.stdin:
        req=json.loads(line);log(req);m=req.get('method');p=req.get('params',{})
        if m=='initialize': reply(req,{'userAgent':'SIMULATED Codex fixture','platformFamily':'unix','platformOs':'macos','codexHome':str(root/'fixture-home')})
        elif m=='initialized': continue
        elif m=='account/read':
            assert p['refreshToken'] is False
            if marker('fixture-mode')=='preflight':
                (root/'fixture-probing').write_text('yes')
                subprocess.run(['/bin/sleep','30'])
            auth=marker('fixture-auth','chatgpt')
            a=None if auth=='signedout' else {'type':auth}
            if auth=='chatgpt': a.update(email=None,planType='free')
            reply(req,{'account':a,'requiresOpenaiAuth':True})
        elif m=='model/list': reply(req,{'data':[{'model':'simulated-codex','displayName':'SIMULATED Codex CLI (no AI)'}],'nextCursor':None})
        elif m in ('thread/start','thread/resume'):
            assert p['cwd']==os.getcwd() and p['sandbox']=='read-only' and p['approvalPolicy']=='never'
            thread=p.get('threadId','simulated-thread-'+str(uuid.uuid4()))
            reply(req,{'thread':{'id':thread},'model':'simulated-codex','cwd':os.getcwd(),'approvalPolicy':'never','approvalsReviewer':'user','modelProvider':'openai','sandbox':{'type':'readOnly','networkAccess':False}})
        elif m=='turn/start':
            assert p['sandboxPolicy']=={'type':'readOnly','networkAccess':False} and p['model']=='simulated-codex'
            thread=p['threadId'];tid='simulated-turn-'+str(uuid.uuid4());active=(thread,tid)
            reply(req,{'turn':{'id':tid}})
            text='SIMULATED Codex CLI response. No AI service was contacted. '
            notify('item/agentMessage/delta',{'threadId':thread,'turnId':tid,'itemId':'simulated-item','delta':text})
            # Stay responsive to Stop without a blocking sleep or a real model/network call.
            child=subprocess.Popen(['/bin/sleep','30'])
            log({'method':'owned-child','pid':child.pid})
            if p['input'][0]['text']=='fixture-complete':
                notify('turn/completed',{'threadId':thread,'turn':{'id':tid,'status':'completed','items':[item(text+'Completed locally.')]}})
        elif m=='turn/interrupt':
            assert active==(p['threadId'],p['turnId'])
            reply(req,{})
            notify('item/agentMessage/delta',{'threadId':active[0],'turnId':active[1],'itemId':'simulated-item','delta':'LATE AFTER STOP'})
        else: raise RuntimeError('Unsupported fixture request')
    """#
}
