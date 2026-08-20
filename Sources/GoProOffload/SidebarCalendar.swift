import SwiftUI

/// Month grid of the days that actually have media, for either source. Days
/// with nothing on them stay flat and unclickable, so the calendar doubles as
/// a picture of when you shot.
///
/// Camera timestamps carry no timezone and are formatted in UTC everywhere
/// else in the app; this grid uses the same UTC calendar so a day here holds
/// exactly the items the grid's day heading holds.
struct SidebarCalendar: View {
    @EnvironmentObject var model: AppModel
    @State private var month: Date = .distantPast
    @State private var hoveredDay: String?

    private static var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static let monthTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    /// Day keys that have at least one item, and the newest day overall.
    private var populated: Set<String> {
        Set(model.entries.map { Fmt.dayKey.string(from: $0.created) })
    }

    private var newest: Date? { model.entries.map(\.created).max() }

    var body: some View {
        // The month is the card's title; the steppers ride in its title row.
        SidebarCard(title: Self.monthTitle.string(from: month)) {
            HStack(spacing: 4) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                Button { step(1) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.semibold))
        } content: {
            grid
        }
        .onAppear { if month == .distantPast { month = startOfMonth(newest ?? Date()) } }
        // A new library (or the other source) may have nothing in this month.
        .onChange(of: newest) { if let n = newest, populated.isEmpty || month == .distantPast { month = startOfMonth(n) } }
    }

    private var grid: some View {
        let days = daysInMonth()
        let marked = populated
        return VStack(spacing: 8) {
            HStack(spacing: 5) {
                ForEach(Array(Self.cal.veryShortStandaloneWeekdaySymbols.enumerated()), id: \.offset) { _, s in
                    Text(s)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(days.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 5) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        if let day {
                            dayCell(day, hasItems: marked.contains(Fmt.dayKey.string(from: day)))
                        } else {
                            Color.clear.frame(maxWidth: .infinity).frame(height: 26)
                        }
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Date, hasItems: Bool) -> some View {
        let key = Fmt.dayKey.string(from: day)
        let selected = model.dayFilter == key
        return Text("\(Self.cal.component(.day, from: day))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(selected ? Accent.ink
                             : (hasItems ? Color.primary : Color.secondary.opacity(0.35)))
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background {
                if selected {
                    Circle().fill(Color.accentColor)
                } else if hasItems {
                    // Hover brightens the circle a step.
                    Circle().fill(hoveredDay == key ? AnyShapeStyle(.tertiary)
                                                    : AnyShapeStyle(.quaternary))
                }
            }
            .contentShape(Circle())
            .onHover { inside in
                guard hasItems else { return }
                hoveredDay = inside ? key : (hoveredDay == key ? nil : hoveredDay)
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .animation(.easeOut(duration: 0.1), value: hoveredDay)
            .onTapGesture {
                guard hasItems else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    model.dayFilter = selected ? nil : key
                }
            }
            .help(hasItems ? Fmt.dayTitle.string(from: day) : "")
    }

    private func step(_ months: Int) {
        if let next = Self.cal.date(byAdding: .month, value: months, to: month) { month = next }
    }

    private func startOfMonth(_ date: Date) -> Date {
        Self.cal.date(from: Self.cal.dateComponents([.year, .month], from: date)) ?? date
    }

    /// Weeks of the shown month, padded with nils so each row is 7 columns.
    private func daysInMonth() -> [[Date?]] {
        guard let range = Self.cal.range(of: .day, in: .month, for: month) else { return [] }
        let first = startOfMonth(month)
        let leading = Self.cal.component(.weekday, from: first) - Self.cal.firstWeekday
        var cells: [Date?] = Array(repeating: nil, count: (leading + 7) % 7)
        for day in range {
            cells.append(Self.cal.date(byAdding: .day, value: day - 1, to: first))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }
}
