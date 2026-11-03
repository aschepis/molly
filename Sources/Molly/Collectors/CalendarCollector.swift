import Foundation

/// Meeting load from Calendar.sqlitedb. Reads the OccurrenceCache (recurring
/// events already expanded by Calendar) and never selects titles, locations,
/// attendees or notes. Calendar names are published only via the `calendars`
/// label policy.
struct CalendarOccurrence {
    let start: Double
    let end: Double
    let allDay: Bool
    let calendar: String
}

struct CalendarDay {
    let start: Double
    let end: Double
}

struct CalendarSummary: Equatable {
    var eventsByCalendar: [String: Double] = [:]
    var eventSeconds: Double = 0
    var secondsRemaining: Double = 0
    var inEvent = false
    var secondsUntilNext: Double = -1
}

enum CalendarQueries {
    static let cancelledStatus = 3
    static let unknownCalendar = "unknown"

    /// Non-hidden, non-cancelled occurrences overlapping [day.start, day.end), seconds since 2001.
    static func occurrences(db: SQLiteDatabase, day: CalendarDay) throws -> [CalendarOccurrence] {
        let rows: [SQLiteRow]
        do {
            rows = try db.query("""
                SELECT o.occurrence_date AS start, COALESCE(o.occurrence_end_date, o.occurrence_date) AS end,
                       c.all_day AS all_day, cal.title AS calendar
                FROM OccurrenceCache o
                JOIN CalendarItem c ON c.ROWID = o.event_id
                LEFT JOIN Calendar cal ON cal.ROWID = o.calendar_id
                WHERE o.occurrence_date < ? AND COALESCE(o.occurrence_end_date, o.occurrence_date) > ?
                  AND COALESCE(c.hidden, 0) = 0 AND COALESCE(c.status, 0) != ?
                """, bindings: [.real(day.end), .real(day.start), .integer(Int64(cancelledStatus))])
        } catch let error as SQLiteError {
            throw CollectorUnavailable(reason: "Calendar database schema not recognised: \(error)")
        }
        return rows.compactMap { row in
            guard let start = row["start"].double, let end = row["end"].double else { return nil }
            return CalendarOccurrence(start: start, end: end, allDay: (row["all_day"].int ?? 0) != 0,
                                      calendar: row["calendar"].string ?? unknownCalendar)
        }
    }

    /// Start of the first timed event after `now`, or nil.
    static func nextEventStart(db: SQLiteDatabase, after now: Double) throws -> Double? {
        try db.scalar("""
            SELECT MIN(o.occurrence_date) FROM OccurrenceCache o
            JOIN CalendarItem c ON c.ROWID = o.event_id
            WHERE o.occurrence_date > ? AND COALESCE(c.all_day, 0) = 0
              AND COALESCE(c.hidden, 0) = 0 AND COALESCE(c.status, 0) != ?
            """, bindings: [.real(now), .integer(Int64(cancelledStatus))]).double
    }

    /// Timed events only contribute seconds; overlapping meetings are merged so double-booking is not double-counted.
    static func summarize(_ occurrences: [CalendarOccurrence], day: CalendarDay, now: Double, nextStart: Double?) -> CalendarSummary {
        var summary = CalendarSummary()
        for occurrence in occurrences {
            summary.eventsByCalendar[occurrence.calendar, default: 0] += 1
        }
        let timed = occurrences.filter { !$0.allDay }
            .map { (start: max($0.start, day.start), end: min($0.end, day.end)) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var merged: [(start: Double, end: Double)] = []
        for slot in timed {
            if let last = merged.last, slot.start <= last.end {
                merged[merged.count - 1].end = max(last.end, slot.end)
            } else {
                merged.append(slot)
            }
        }
        summary.eventSeconds = merged.reduce(0) { $0 + ($1.end - $1.start) }
        summary.secondsRemaining = merged.reduce(0) { $0 + max(0, $1.end - max($1.start, now)) }
        summary.inEvent = merged.contains { $0.start <= now && now < $0.end }
        if let nextStart { summary.secondsUntilNext = max(0, nextStart - now) }
        return summary
    }
}

final class CalendarCollector: Collector {
    static let calendarsDefaults = LabelPolicy(enabled: false, mode: .denylist, maxCardinality: 50)
    static let defaultPaths = [
        "~/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb",
        "~/Library/Calendars/Calendar.sqlitedb",
    ]

    let name = "calendar"
    let interval: TimeInterval

    private let configuredPath: String?
    private let calendarFilter: LabelFilter
    private let now: () -> Date
    private let calendar: Calendar

    private var eventsToday: Gauge?
    private var eventSecondsToday: Gauge?
    private var secondsRemaining: Gauge?
    private var inEvent: Gauge?
    private var nextEventStart: Gauge?

    init(settings: CollectorSettings, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) throws {
        interval = settings.interval(default: 300)
        configuredPath = settings.raw["path"]?.stringValue.map(Paths.expand)
        calendarFilter = try settings.filter("calendars", defaults: CalendarCollector.calendarsDefaults)
        self.now = now
        self.calendar = calendar
    }

    func start(registry: MetricsRegistry) throws {
        eventsToday = registry.gauge("molly_calendar_events_today", help: "Calendar events overlapping today, per calendar (one 'redacted' series unless the calendars label policy is enabled).", labels: ["calendar"])
        eventSecondsToday = registry.gauge("molly_calendar_event_seconds_today", help: "Seconds of timed events today, overlaps merged, all-day events excluded.")
        secondsRemaining = registry.gauge("molly_calendar_event_seconds_remaining_today", help: "Seconds of timed events still ahead today.")
        inEvent = registry.gauge("molly_calendar_in_event", help: "1 while a timed event is in progress.")
        nextEventStart = registry.gauge("molly_calendar_next_event_start_seconds", help: "Seconds until the next timed event starts, -1 if none is scheduled.")
    }

    func collect() throws {
        let path = try resolvePath()
        let db = try SQLiteSnapshot.open(path: path)
        let current = now()
        let start = calendar.startOfDay(for: current)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let day = CalendarDay(start: CocoaTime.cocoaSeconds(start), end: CocoaTime.cocoaSeconds(end))
        let nowSeconds = CocoaTime.cocoaSeconds(current)

        let occurrences = try CalendarQueries.occurrences(db: db, day: day)
        let next = try CalendarQueries.nextEventStart(db: db, after: nowSeconds)
        let summary = CalendarQueries.summarize(occurrences, day: day, now: nowSeconds, nextStart: next)

        eventsToday?.replaceAll(calendarFilter.labels(summary.eventsByCalendar), label: "calendar")
        eventSecondsToday?.set(summary.eventSeconds)
        secondsRemaining?.set(summary.secondsRemaining)
        inEvent?.set(summary.inEvent ? 1 : 0)
        nextEventStart?.set(summary.secondsUntilNext)
    }

    private func resolvePath() throws -> String {
        if let configuredPath { return configuredPath }
        let expanded = Self.defaultPaths.map(Paths.expand)
        guard let found = expanded.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw CollectorUnavailable(reason: "Calendar.sqlitedb not found (looked in \(expanded.joined(separator: ", ")))")
        }
        return found
    }
}
