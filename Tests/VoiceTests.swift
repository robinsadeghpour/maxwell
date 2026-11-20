import Foundation

/// Voice mode's lines, what a spoken reply means, and whose turn it is to be asked.
func voiceTests() {
    // Lines
    check(VoiceLine.announcement(title: "Billing", question: "Should I **migrate** first?", name: "Ada") == "Hey Ada. Billing needs you. Should I migrate first?",
          "an announcement greets by name and reads the question without markdown")
    check(VoiceLine.announcement(title: "Billing", question: "Go?", name: "") == "Billing needs you. Go?", "no name, no greeting")
    check(VoiceLine.spoken("Run `npm test`, see [the log](https://x.test/log) or https://x.test/raw\n```\nrm -rf\n```\ndone") == "Run npm test, see the log or a link a code block done",
          "code marks, links and code blocks are not read out")
    let long = String(repeating: "This sentence is here to fill the reply. ", count: 20)
    let cut = VoiceLine.spoken(long)
    check(cut.count < long.count && cut.hasSuffix("reply. There is more in Maxwell."), "a long question is cut at a sentence and says there is more")
    check(VoiceLine.greeting(waiting: 0).contains("Nothing needs you") && VoiceLine.greeting(waiting: 1).contains("One session") && VoiceLine.greeting(waiting: 3).contains("3 sessions"),
          "the greeting counts who is waiting")

    // What a reply means
    check(VoiceLine.heard("Blue, please.") == .answer("Blue, please."), "a reply is passed on word for word")
    check(VoiceLine.heard(" Skip. ") == .skip && VoiceLine.heard("später") == .skip, "skip, in English and German")
    check(VoiceLine.heard("Skip the tests and deploy") == .answer("Skip the tests and deploy"), "a command word inside a sentence is still an answer")
    check(VoiceLine.heard("Repeat") == .again && VoiceLine.heard("nochmal") == .again, "repeat")
    check(VoiceLine.heard("Goodbye!") == .hangUp, "goodbye turns voice mode off")
    check(VoiceLine.heard("Deploy it. No wait, cancel") == .cancel && VoiceLine.heard("cancel") == .cancel, "cancel at the end takes the reply back")
    check(VoiceLine.heard("Cancel the subscription and refund them") == .answer("Cancel the subscription and refund them"), "cancel at the start is an answer")
    check(VoiceLine.heard("  ") == .cancel, "nothing heard sends nothing")

    // Whose turn
    func ask(_ id: String, _ q: String, answerable: Bool = true) -> VoiceCall.Asking { .init(id: id, question: q, answerable: answerable) }
    var call = VoiceCall()
    check(call.update([]) == [] && call.onLine == nil, "nobody asks, nothing is said")
    check(call.update([ask("a", "A?"), ask("b", "B?")]) == [.announce("a", "A?")] && call.onLine == "a" && call.waiting == ["b"],
          "the oldest is announced, the other waits")
    check(call.update([ask("a", "A?"), ask("b", "B?")]) == [], "the same questions again are not news")
    check(call.update([ask("a", "A?"), ask("b", "B?"), ask("c", "C?")]) == [.mention("c")] && call.waiting == ["b", "c"],
          "a session that starts waiting while another is on the line is only named")
    check(call.update([ask("a", "A2?"), ask("b", "B?"), ask("c", "C?")]) == [.announce("a", "A2?")], "a new question from the session on the line is read out")
    call.release()
    check(call.update([ask("a", "A2?"), ask("b", "B?"), ask("c", "C?")]) == [.announce("b", "B?")] && call.onLine == "b",
          "after an answer or a skip the next one is announced, and the skipped one isn't asked again")
    check(call.update([ask("a", "A2?"), ask("c", "C?")]) == [.announce("c", "C?")] && call.onLine == "c",
          "a session answered some other way frees the line for the next")
    check(call.update([ask("a", "A2?")]) == [] && call.onLine == nil, "a skipped session alone says nothing")
    check(call.update([ask("a", "A3?")]) == [.announce("a", "A3?")], "until it asks something new")
    var perm = VoiceCall()
    check(perm.update([ask("p", "Claude needs your permission to use Bash", answerable: false)]) == [.tell("p", "Claude needs your permission to use Bash")] && perm.onLine == nil,
          "a permission prompt is said but never put on the line")
}
