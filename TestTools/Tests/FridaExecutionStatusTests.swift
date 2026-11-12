import Foundation
@main struct FridaExecutionStatusTests {
    static func main() {
        let record: [String:Any] = ["pid":321,"state":"running","startedAt":100.0]
        let loaded: [[String:Any]] = [["file":"FridaGadget.dylib","status":"loaded"]]
        let phone: [String:Any] = ["pid":321,"startedAt":100.1,"frida":["automatic":true,"scriptCount":2],"plugins":loaded]
        let pc: [String:Any] = ["pid":321,"startedAt":100.1,"frida":["automatic":false,"scriptCount":0],"plugins":loaded]
        let client: [String:Any] = ["pid":321,"connected":true,"heartbeat":110.0,"scripts":[["name":"pc.js","state":"loaded"],["name":"bad.js","state":"error"]]]
        let a = LCFridaExecutionStatus.evaluate(record:record,session:phone,client:client,now:111)
        precondition(a.mode == "手机自动脚本" && a.phone.contains("2") && a.computer.contains("未启用"))
        let b = LCFridaExecutionStatus.evaluate(record:record,session:pc,client:client,now:111)
        precondition(b.mode == "电脑连接脚本" && b.phone.contains("未启用") && b.computer.contains("1 个已加载") && b.computer.contains("1 个失败"))
        let unknown = LCFridaExecutionStatus.evaluate(record:record,session:pc,client:nil,now:111)
        precondition(unknown.computer.contains("等待电脑回传"))
        let stale = LCFridaExecutionStatus.evaluate(record:record,session:pc,client:client,now:120)
        precondition(stale.computer.contains("过期"))
        var other = client; other["pid"] = 999
        precondition(LCFridaExecutionStatus.evaluate(record:record,session:pc,client:other,now:111).computer.contains("等待电脑回传"))
        var oldSession = phone; oldSession["startedAt"] = 90.0
        precondition(LCFridaExecutionStatus.evaluate(record:record,session:oldSession,client:client,now:111).mode.contains("等待"))
        var exited = record; exited["state"]="exited"
        precondition(LCFridaExecutionStatus.evaluate(record:exited,session:phone,client:client,now:111).mode == "目标未运行")
        precondition(LCFridaLogSource.phone.accepts(phone) && !LCFridaLogSource.phone.accepts(pc))
        precondition(!LCFridaLogSource.phone.accepts([:]) && LCFridaLogSource.process.accepts([:]))
        precondition(LCFridaLogSource.phone.exportName(session:"session-1",raw:false).hasPrefix("phone-auto-"))
        precondition(LCFridaLogSource.computer.exportName(session:"client-1",raw:false).hasPrefix("computer-scripts-"))
        precondition(LCFridaLogSource.process.exportName(session:"session-1",raw:true).hasPrefix("process-console-"))
        let raw = "{\"source\":\"computer\",\"message\":{\"source\":\"demo.js\",\"message\":{\"type\":\"log\",\"level\":\"info\",\"payload\":\"fixture\"}}}"
        precondition(LCFridaComputerLogFormatter.text(raw) == "[电脑][demo.js][info] fixture")
        precondition(LCFridaComputerLogFormatter.text("partial-json") == "partial-json")
        print("PASS: phone/computer runtime evidence, stale/wrong-PID rejection, log routing and export provenance")
    }
}
