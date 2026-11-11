import Foundation
import AppKit

func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a == b, "Expected \(b), got \(a)") }
func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
func XCTAssertNotNil<T>(_ value: T?) { precondition(value != nil) }

@main
@MainActor
struct DeadlineTests {
    static func main() async throws {
        let tests = DeadlineTests()
        tests.testUpcomingIncludesTodayExcludesPastAndCompletedAndSorts()
        tests.testLinksRejectUnsafeSchemes()
        try tests.testSavedDataRoundTrip()
        try await tests.testSharedFile()
        try tests.testWritingSessions()
        tests.testOverleafProject()
        tests.testYearCalendar()
        tests.testConferenceSharedDetails()
        tests.testBatchUpsert()
        tests.testClipboardImport()
        tests.testBrowserLinks()
        try tests.testHAICImport()
        try tests.testConferenceImport()
        try tests.testLegacyDataAndDetails()
        tests.testCountdownAndCalendar()
        print("Passed: conference extraction, links, cutoff time zone, missing dates, details migration, countdown, calendar export, deadline ordering/filtering, safe links, persistence round trip")
    }
    func testUpcomingIncludesTodayExcludesPastAndCompletedAndSorts() {
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let items = [Deadline(date: tomorrow, name: "Later", kind: "Paper", link: ""), Deadline(date: yesterday, name: "Past", kind: "Paper", link: ""), Deadline(date: today, name: "Today", kind: "Abstract", link: ""), Deadline(date: tomorrow, name: "Done", kind: "Review", link: "", completed: true)]
        XCTAssertEqual(Deadline.upcoming(items, now: today.addingTimeInterval(3600)).map(\.name), ["Today", "Later"])
    }
    func testLinksRejectUnsafeSchemes() {
        for link in ["file:///etc/passwd", "javascript:alert(1)", "example.com", "https://"] { XCTAssertNil(Deadline(date: Date(), name: "Test", kind: "Letter", link: link).url) }
        XCTAssertNotNil(Deadline(date: Date(), name: "Test", kind: "Letter", link: "https://example.com/event").url)
    }
    func testSavedDataRoundTrip() throws {
        let data = SavedData(deadlines: [Deadline(date: Date(), name: "Conference", kind: "Proposal", link: "https://example.com")], kinds: ["Proposal"])
        let restored = try JSONDecoder().decode(SavedData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(restored.deadlines, data.deadlines)
        XCTAssertEqual(restored.kinds, data.kinds)
    }
    func testLegacyDataAndDetails() throws {
        let legacy = Data("{\"date\":0,\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"Existing\",\"kind\":\"Paper\",\"link\":\"\",\"completed\":false}".utf8)
        var deadline = try JSONDecoder().decode(Deadline.self, from: legacy)
        XCTAssertEqual(deadline.name, "Existing")
        XCTAssertNil(deadline.fullName)
        XCTAssertNil(deadline.overleafProjectURL)
        XCTAssertNil(deadline.about)
        XCTAssertNil(deadline.actions)
        deadline.about = "Investigate how people collaborate with AI."
        deadline.actions = [DeadlineAction(title: "Write outline"), DeadlineAction(title: "Read related work", completed: true)]
        deadline.fullName = "Full conference name"
        deadline.eventDates = "June 20–25, 2027"
        deadline.location = "Seattle, WA"
        deadline.notes = "Abstract due earlier"
        deadline.topics = "computer vision, machine learning"
        deadline.hasTime = true
        deadline.timeZoneIdentifier = "Etc/GMT+12"
        XCTAssertEqual(try JSONDecoder().decode(Deadline.self, from: JSONEncoder().encode(deadline)), deadline)
        XCTAssertEqual(deadline.topicList, ["computer vision", "machine learning"])
    }
    func testCountdownAndCalendar() {
        let now = Date(timeIntervalSince1970: 1700000000)
        var deadline = Deadline(date: now.addingTimeInterval(90061), name: "Paper, 2027", kind: "Paper", link: "https://example.com")
        deadline.hasTime = true
        deadline.notes = "First line\nSecond; line"
        XCTAssertEqual(deadline.countdown(now: now), "01 days 01h 01m 01s")
        XCTAssertEqual(deadline.countdown(now: deadline.date), "Deadline passed")
        let file = deadline.calendarFile(now: now)
        precondition(file.contains("SUMMARY:Paper\\, 2027"))
        precondition(file.contains("First line\\nSecond\\; line"))
        precondition(file.contains("DTSTART:") && file.hasSuffix("END:VCALENDAR\r\n"))
        deadline.hasTime = false
        precondition(deadline.calendarFile(now: now).contains("DTSTART;VALUE=DATE:"))
    }

    func testConferenceImport() throws {
        let html = """
        <html><head><title>TESTCONF 2027</title><script type="application/ld+json">{"@type":"Event","name":"TESTCONF 2027: Example Conference","startDate":"2027-06-20","endDate":"2027-06-25","location":{"name":"Convention Center","address":{"addressLocality":"Seattle"}},"keywords":"vision, learning"}</script></head>
        <body><a href="/2027/cfp">Call for papers</a><table>
        <tr><td>Abstract deadline</td><td>November 10, 2026 23:59 UTC-12</td></tr>
        <tr><td>Paper submission deadline</td><td>November 17, 2026 23:59 UTC-12</td></tr>
        <tr><td>Acceptance notification</td><td>December 20, 2026</td></tr>
        </table><script>Paper deadline January 1, 2099</script></body></html>
        """
        let page = try ConferenceImporter.parse(html: html, url: URL(string: "https://example.com/2027/")!)
        XCTAssertEqual(page.links.map(\.absoluteString), ["https://example.com/2027/cfp"])
        let draft = ConferenceImporter.draft(from: [page])
        XCTAssertEqual(draft.candidates.count, 2)
        XCTAssertEqual(draft.candidates.map(\.kind), ["Abstract", "Paper"])
        XCTAssertEqual(draft.deadline.location, "Convention Center, Seattle")
        XCTAssertEqual(draft.deadline.topicList, ["vision", "learning"])
        XCTAssertEqual(draft.candidates[0].timeZone, "Etc/GMT+12")
        precondition(draft.candidates[0].hasTime)
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(formatter.string(from: draft.candidates[0].date), "2026-11-11T11:59:00Z")
        let missing = try ConferenceImporter.parse(html: "<html><title>Example</title><body><p>Conference in June 2027</p><p>Paper deadline: coming soon</p></body></html>", url: URL(string: "https://example.com")!)
        XCTAssertEqual(ConferenceImporter.candidates(in: missing).count, 0)
        XCTAssertNil(ConferenceImporter.webURL("file:///etc/passwd"))
        XCTAssertNil(ConferenceImporter.webURL("https://user:password@example.com"))
    }

    func testHAICImport() throws {
        let html = try String(contentsOfFile: "Tests/Fixtures/haic.html", encoding: .utf8)
        let page = try ConferenceImporter.parse(html: html, url: URL(string: "https://haic.cc/#/home")!)
        let draft = ConferenceImporter.draft(from: [page])
        XCTAssertEqual(draft.deadline.name, "HAIC 2027")
        XCTAssertEqual(draft.deadline.fullName, "The 1st Human–AI Interaction Conference")
        XCTAssertEqual(draft.deadline.eventDates, "June 27–30, 2027")
        XCTAssertEqual(draft.deadline.location, "Washington, DC")
        XCTAssertEqual(draft.candidates.map(\.kind), ["Abstract", "Paper"])
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(draft.candidates.map { formatter.string(from: $0.date) }, ["2027-01-21", "2027-01-28"])
        precondition(draft.candidates.allSatisfy { !$0.hasTime })
    }

    func testBrowserLinks() {
        let image = "http://aideadlines.org/static/img/203-earth.svg"
        let ecai = "<a href='https://ecai2027.org/'><img src='\(image)' title='Link to Conference Website'></a>"
        XCTAssertEqual(BrowserLink.preferred([(image, false), (ecai, true)])?.absoluteString, "https://ecai2027.org/")
        let archive: [String: Any] = ["WebMainResource": ["WebResourceData": Data(ecai.utf8)]]
        let archiveData = try! PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        XCTAssertEqual(BrowserLink.archiveHTML(archiveData), ecai)
        let urlList = try! PropertyListSerialization.data(fromPropertyList: [["https://ecai2027.org/"], ["Link to Conference Website"]], format: .binary, options: 0)
        XCTAssertEqual(BrowserLink.browserURLList(urlList), "https://ecai2027.org/")
        let html = "<a href='https://haic.cc/#/home'><img src='\(image)' alt='Link to Conference Website'></a>"
        XCTAssertEqual(BrowserLink.preferred([(image, false), (html, true)])?.absoluteString, "https://haic.cc/#/home")
        XCTAssertEqual(BrowserLink.preferred([("[Conference](https://haic.cc/#/home)", false)])?.absoluteString, "https://haic.cc/#/home")
        precondition(BrowserLink.isImage(BrowserLink.preferred([("[Link to Conference Website](\(image))", false)])!))
        XCTAssertEqual(BrowserLink.extract("https://haic.cc/#/home\nConference title").first?.absoluteString, "https://haic.cc/#/home")
        XCTAssertEqual(BrowserLink.extract("<base href='https://example.com'><a href='/cfp'><img src='icon.svg'></a>", html: true).first?.absoluteString, "https://example.com/cfp")
        XCTAssertEqual(BrowserLink.extract("<a href='javascript:alert(1)'><img src='https://example.com/icon.svg'></a>", html: true).count, 0)
    }

    func testClipboardImport() {
        let clipboard = NSPasteboard(name: NSPasteboard.Name("DeadlineStartup-tests-" + UUID().uuidString))
        defer { clipboard.releaseGlobally() }
        clipboard.clearContents()
        clipboard.setString("https://ecai2027.org/", forType: .string)
        XCTAssertEqual(ConferenceClipboard.url(from: clipboard)?.absoluteString, "https://ecai2027.org/")
        clipboard.clearContents()
        clipboard.setString("http://aideadlines.org/static/img/203-earth.svg", forType: .URL)
        clipboard.setString("<a href='https://ecai2027.org/'><img src='globe.svg'></a>", forType: .html)
        XCTAssertEqual(ConferenceClipboard.url(from: clipboard)?.absoluteString, "https://ecai2027.org/")
        clipboard.clearContents()
        clipboard.setString("plain text without a URL", forType: .string)
        XCTAssertNil(ConferenceClipboard.url(from: clipboard))
    }

    func testBatchUpsert() {
        let original = Deadline(date: Date(), name: "Conference", kind: "Abstract", link: "https://example.com")
        var updated = original; updated.notes = "Updated details"
        let paper = Deadline(date: Date(), name: "Conference", kind: "Paper", link: "https://example.com")
        let custom = Deadline(date: Date(), name: "Conference", kind: "Demo", link: "https://example.com")
        let saved = SavedData(deadlines: [original]).upserting([updated, paper, custom])
        XCTAssertEqual(saved.deadlines.count, 3)
        XCTAssertEqual(saved.deadlines[0].notes, "Updated details")
        XCTAssertEqual(saved.upserting([updated, paper, custom]).deadlines.count, 3)
        precondition(saved.kinds.contains("Demo"))
    }

    func testSharedFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeadlineFile-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("deadlines.json")
        let first = DeadlineFile(url: url, isCloud: false)
        let initial = try await first.load()
        XCTAssertNil(initial.bytes)
        let deadline = Deadline(date: Date(), name: "Shared conference", kind: "Paper", link: "https://example.com")
        let bytes = try await first.save(SavedData(deadlines: [deadline]), expected: nil)
        let second = DeadlineFile(url: url, isCloud: true)
        let loaded = try await second.load()
        XCTAssertEqual(loaded.data.deadlines, [deadline])
        var changed = deadline; changed.notes = "Changed on another Mac"
        changed.about = "Paper description"
        changed.actions = [DeadlineAction(title: "Draft introduction", completed: true)]
        let remoteBytes = try await second.save(SavedData(deadlines: [changed]), expected: loaded.bytes)
        let roundTrip = try await first.load()
        XCTAssertEqual(roundTrip.data.deadlines.first?.about, changed.about)
        XCTAssertEqual(roundTrip.data.deadlines.first?.actions, changed.actions)
        do {
            _ = try await first.save(SavedData(deadlines: [deadline]), expected: bytes)
            preconditionFailure("Stale data must not overwrite the shared file")
        } catch DeadlineFileError.changed { }
        XCTAssertEqual(try Data(contentsOf: url), remoteBytes)
        let absent = DeadlineFile(url: directory.appendingPathComponent("missing.json"), isCloud: true)
        do { _ = try await absent.load(); preconditionFailure("Missing cloud data must not become an empty file") }
        catch { }
        let corrupt = Data("Unreadable file".utf8)
        try corrupt.write(to: url)
        do { _ = try await second.load(); preconditionFailure("Corrupt data must not be accepted") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testConferenceSharedDetails() {
        var abstract = Deadline(date: Date(), name: "HAIC 2027", kind: "Abstract", link: "https://haic.cc/#/home")
        abstract.about = "A paper about collaboration"
        abstract.actions = [DeadlineAction(title: "Write outline", completed: true)]
        let paper = Deadline(date: Date().addingTimeInterval(86400), name: "HAIC 2027", kind: "Paper", link: "https://haic.cc/#/cfp")
        let nextYear = Deadline(date: Date(), name: "HAIC 2028", kind: "Paper", link: "https://haic.cc/#/home")
        let unrelated = Deadline(date: Date(), name: "ESWC 2027", kind: "Paper", link: "https://example.com")
        let original = SavedData(deadlines: [abstract, paper, nextYear, unrelated])
        let shared = original.sharingExistingDetails()
        XCTAssertEqual(shared.deadlines[1].about, abstract.about)
        XCTAssertEqual(shared.deadlines[1].actions, abstract.actions)
        XCTAssertNil(shared.deadlines[2].about)
        XCTAssertNil(shared.deadlines[3].actions)
        XCTAssertEqual(shared.sharingExistingDetails().deadlines, shared.deadlines)
        var edited = paper
        edited.about = "Revised idea"; edited.actions = []
        let saved = shared.sharingDetails(from: edited)
        XCTAssertEqual(saved.deadlines[0].about, "Revised idea")
        XCTAssertEqual(saved.deadlines[0].actions, [])
        XCTAssertEqual(saved.deadlines[0].date, abstract.date)
        XCTAssertEqual(saved.deadlines[0].kind, "Abstract")
        let extra = Deadline(date: Date(), name: "HAIC 2027", kind: "Review", link: "https://haic.cc/")
        let imported = shared.upserting([extra])
        XCTAssertEqual(imported.deadlines.last?.actions, abstract.actions)
        var conflicting = paper
        conflicting.about = "Another paragraph"
        conflicting.actions = [DeadlineAction(title: "Run analysis")]
        let merged = SavedData(deadlines: [abstract, conflicting]).sharingExistingDetails()
        precondition(merged.deadlines[0].about!.contains("Another paragraph"))
        XCTAssertEqual(merged.deadlines[0].actions?.count, 2)
    }

    func testYearCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11))!
        let model = DeadlineCalendar(now: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: model.start), 1)
        XCTAssertEqual(calendar.component(.month, from: model.start), 11)
        XCTAssertEqual(calendar.component(.year, from: model.end), 2027)
        XCTAssertEqual(model.months.count, 12)
        XCTAssertEqual(calendar.component(.weekday, from: model.gridStart), 1)
        precondition(!model.contains(model.end))
        let deadline = Deadline(date: now, name: "Conference", kind: "Abstract", link: "")
        var completed = deadline; completed.id = UUID(); completed.completed = true
        let paper = Deadline(date: now.addingTimeInterval(3600), name: "Conference", kind: "Paper", link: "")
        XCTAssertEqual(model.deadlines(on: now, from: [deadline, completed, paper]).count, 2)
        for month in model.months {
            let column = model.column(for: month)
            precondition((0..<model.weekCount).contains(column))
            precondition((0..<7).contains { calendar.isDate(model.date(week: column, weekday: $0), inSameDayAs: month) })
        }
        let leap = DeadlineCalendar(now: calendar.date(from: DateComponents(year: 2023, month: 3, day: 1))!, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day], from: leap.start, to: leap.end).day, 366)
    }

    func testOverleafProject() {
        let link = "https://www.overleaf.com/project/0123456789abcdef01234567"
        XCTAssertEqual(OverleafProject.projectURL(link + "?foo=bar")?.absoluteString, link)
        for invalid in ["https://overleaf.com.evil.test/project/0123456789abcdef01234567", "http://www.overleaf.com/project/0123456789abcdef01234567", "https://www.overleaf.com/project", "https://www.overleaf.com/project/not-an-id"] {
            XCTAssertNil(OverleafProject.projectURL(invalid))
        }
        let request = OverleafProject.creationRequest(name: "Conference & 50%_test")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://www.overleaf.com/docs")
        let fields = String(data: request.httpBody!, encoding: .utf8)!.split(separator: "&").map { $0.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding! } }
        let uri = fields.first { $0[0] == "snip_uri" }![1]
        let content = String(data: Data(base64Encoded: String(uri.split(separator: ",", maxSplits: 1)[1]))!, encoding: .utf8)!
        precondition(content.contains("\\title{Conference \\& 50\\%\\_test}"))
        var abstract = Deadline(date: Date(), name: "HAIC 2027", kind: "Abstract", link: "")
        abstract.about = "Preserve description"
        let paper = Deadline(date: Date(), name: "HAIC 2027", kind: "Paper", link: "")
        let linked = SavedData(deadlines: [abstract, paper]).linkingOverleaf(link, for: abstract)
        precondition(linked.deadlines.allSatisfy { $0.overleafProjectURL == link })
        XCTAssertEqual(linked.deadlines[0].about, abstract.about)
        var source = abstract; source.overleafProjectURL = link
        let inherited = SavedData(deadlines: [source]).upserting([paper])
        XCTAssertEqual(inherited.deadlines[1].overleafProjectURL, link)
    }

    func testWritingSessions() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 23, minute: 59, second: 30))!
        let abstract = Deadline(date: start, name: "HAIC 2027", kind: "Abstract", link: "https://haic.cc")
        let paper = Deadline(date: start, name: "HAIC 2027", kind: "Paper", link: "https://haic.cc")
        let session = WritingSession(deadline: abstract, now: start, calendar: calendar)
        let sixty = session.checkpoint(at: start.addingTimeInterval(60))
        let closed = session.checkpoint(at: start.addingTimeInterval(61))
        precondition(!WritingSession.greenDay(start, sessions: [sixty], calendar: calendar))
        precondition(WritingSession.greenDay(start, sessions: [closed], calendar: calendar))
        precondition(!WritingSession.greenDay(start.addingTimeInterval(86400), sessions: [closed], calendar: calendar))
        precondition(closed.belongs(to: paper))
        let merged = WritingSession.merging([sixty], [closed])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].seconds, 61)
        // Closed records have fixed duration even when read much later.
        XCTAssertEqual(try JSONDecoder().decode(WritingSession.self, from: JSONEncoder().encode(closed)).seconds, 61)
        let reopened = WritingSession(deadline: paper, now: start.addingTimeInterval(120), calendar: calendar).checkpoint(at: start.addingTimeInterval(150))
        let sessions = WritingSession.merging(merged, [reopened])
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.seconds }, 91)
        let document = SavedData(deadlines: [abstract, paper], writingSessions: sessions)
        let loaded = try JSONDecoder().decode(SavedData.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(loaded.writingSessions, sessions)
        XCTAssertEqual(loaded.upserting([paper]).writingSessions, sessions)
        XCTAssertEqual(WritingSession.duration(3661), "1h 01m 01s")
    }

}
