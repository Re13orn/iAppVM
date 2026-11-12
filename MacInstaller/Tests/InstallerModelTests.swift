import Foundation
@main struct ModelTests {
    @MainActor static func main() {
        let m = InstallerModel()
        m.accept(Data("{\"event\":\"devices\",\"devices\":[{\"udid\":\"fixture\",\"name\":\"Phone\",\"version\":\"26.3\",\"paired\":true}]}\n".utf8))
        assert(m.selected == "fixture" && m.phones.count == 1)
        m.email = "user@example.test"; m.password = "fixture"; assert(m.ready)
        m.busy = true; assert(!m.ready)
        // A partial JSON-line must not mutate visible state.
        m.accept(Data("{\"event\":\"progr".utf8)); assert(m.progress == 0)
        m.accept(Data("ess\",\"stage\":\"install\",\"progress\":0.62,\"message\":\"fixture\"}\n".utf8))
        assert(m.progress == 0.62 && m.stage == "install" && !m.completed)
        m.accept(Data("{\"event\":\"open_app\",\"message\":\"open phone\"}\n".utf8))
        assert(m.openApp && m.busy && !m.completed)
        m.accept(Data("{\"event\":\"prompt\",\"id\":\"request\",\"kind\":\"team\",\"data\":{\"teams\":[{\"id\":\"TEAM\",\"name\":null}]}}\n".utf8))
        assert(m.promptID == "request" && m.prompt != nil)
        m.accept(Data("{\"event\":\"prompt\",\"id\":\"reuse\",\"kind\":\"reuse_certificate\",\"data\":{\"certificates\":[{\"fingerprint\":\"ABC\",\"name\":\"Fixture\"}]}}\n".utf8))
        assert(m.certificate == "ABC" && m.promptID == "reuse")
        m.accept(Data("{\"event\":\"error\",\"message\":\"probe failed\"}\n".utf8))
        assert(m.error == "probe failed" && !m.completed && !m.busy && m.prompt == nil)
        m.busy = true
        m.accept(Data("{\"event\":\"complete\",\"message\":\"configured\",\"guestExecutionVerified\":false}\n".utf8))
        assert(m.completed && m.progress == 1 && !m.busy)
        let c = InstallerModel(); c.password = "secret"; c.code = "123456"; c.busy = true; c.cancel()
        assert(c.password.isEmpty && c.code.isEmpty && !c.busy && !c.completed)
        print("PASS: device selection, eligibility, fragmented IPC, installed-vs-configured state, prompts, errors, completion and cancellation")
    }
}
