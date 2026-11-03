import XCTest
@testable import Molly

final class MailCollectorTests: GroupBTestCase {
    private func fixture() -> String {
        let t = Int(noon.timeIntervalSince1970)
        return makeDatabase("""
            CREATE TABLE mailboxes(ROWID INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE messages(ROWID INTEGER PRIMARY KEY AUTOINCREMENT, date_received INTEGER, date_sent INTEGER,
                mailbox INTEGER, read INTEGER, deleted INTEGER);
            INSERT INTO mailboxes VALUES (1, 'imap://ACCT/INBOX'), (2, 'imap://ACCT/Sent%20Messages'),
                (3, 'imap://ACCT/Drafts'), (4, 'imap://ACCT/Junk'), (5, 'imap://ACCT/Deleted%20Messages');
            INSERT INTO messages(date_received, date_sent, mailbox, read, deleted) VALUES
              (\(t - 86400 * 5), NULL, 1, 1, 0),
              (\(t - 600), NULL, 1, 0, 0),
              (\(t - 500), NULL, 1, 1, 0),
              (\(t - 400), NULL, 2, 1, 0),
              (\(t - 300), NULL, 3, 0, 0),
              (\(t - 200), NULL, 4, 0, 0),
              (\(t - 100), NULL, 1, 0, 1);
            """)
    }

    func testDirectionClassification() {
        XCTAssertEqual(MailDirection.classify(mailboxURL: "imap://A/INBOX"), .received)
        XCTAssertEqual(MailDirection.classify(mailboxURL: "imap://A/Sent%20Messages"), .sent)
        XCTAssertEqual(MailDirection.classify(mailboxURL: "imap://A/Archive"), .received)
        for skipped in ["Drafts", "Junk", "Deleted%20Messages", "Trash", "Spam"] {
            XCTAssertNil(MailDirection.classify(mailboxURL: "imap://A/\(skipped)"), skipped)
        }
    }

    func testQueries() throws {
        let db = try open(fixture())
        let today = try MailQueries.messagesToday(db: db, since: midnight.timeIntervalSince1970, until: noon.timeIntervalSince1970)
        XCTAssertEqual(today.counts, [.received: 2, .sent: 1])
        XCTAssertEqual(try MailQueries.unread(db: db), 1, "drafts, junk and deleted rows are not unread mail")
        XCTAssertEqual(try MailQueries.newMessages(db: db, afterRowID: 1).counts, [.received: 2, .sent: 1])
    }

    func testCollectorCursorAndSchemaFailure() throws {
        let path = fixture()
        let state = makeFolder()
        let collector = MailCollector(settings: settings("mail", ["path": .string(path)]), stateFolder: state, now: { self.noon }, calendar: utc)
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        try collector.collect()
        XCTAssertEqual(sample(registry, "molly_mail_messages_total{direction=\"received\"}"), 0)
        XCTAssertEqual(sample(registry, "molly_mail_messages_today{direction=\"sent\"}"), 1)
        XCTAssertEqual(sample(registry, "molly_mail_unread "), 1)

        execute("INSERT INTO messages(date_received, mailbox, read, deleted) VALUES (\(Int(noon.timeIntervalSince1970)), 1, 0, 0)", at: path)
        try collector.collect()
        XCTAssertEqual(sample(registry, "molly_mail_messages_total{direction=\"received\"}"), 1)
        try collector.collect()
        XCTAssertEqual(sample(registry, "molly_mail_messages_total{direction=\"received\"}"), 1)

        let broken = MailCollector(settings: settings("mail", ["path": .string(makeDatabase("CREATE TABLE x(y);"))]), stateFolder: makeFolder())
        try broken.start(registry: MetricsRegistry())
        XCTAssertThrowsError(try broken.collect()) { XCTAssertTrue($0 is CollectorUnavailable) }
    }

    func testEnvelopeIndexLookupPrefersNewestVersion() throws {
        let root = makeFolder()
        for version in ["V9", "V10"] {
            let folder = root.appendingPathComponent("\(version)/MailData")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: folder.appendingPathComponent("Envelope Index").path, contents: Data())
        }
        XCTAssertTrue(MailCollector.locateEnvelopeIndex(mailRoot: root.path)?.contains("/V10/") == true)
        XCTAssertNil(MailCollector.locateEnvelopeIndex(mailRoot: root.appendingPathComponent("none").path))
    }
}
