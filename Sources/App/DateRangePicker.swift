import SwiftUI

// 照搬 cc-switch UsageDateRangePicker.tsx：preset 快捷键 + 自定义起止 + 日历 + 结束跟随当前。

enum RangePreset: String, CaseIterable, Identifiable {
    case today, d1, d7, d14, d30, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .today: return "Today"
        case .d1: return "1d"
        case .d7: return "7d"
        case .d14: return "14d"
        case .d30: return "30d"
        case .custom: return "Custom"
        }
    }
}

struct RangeSelection: Equatable {
    var preset: RangePreset = .today
    var customStart: Date? = nil
    var customEnd: Date? = nil
    var liveEnd: Bool = false

    /// 与 usageRange.ts resolveUsageRange 一致
    func resolve(now: Date = Date(), cal: Calendar = .current) -> (Int64, Int64) {
        let end = Int64(now.timeIntervalSince1970)
        switch preset {
        case .today:
            return (Int64(cal.startOfDay(for: now).timeIntervalSince1970), end)
        case .d1:
            return (end - 86400, end)
        case .d7, .d14, .d30:
            let days = preset == .d7 ? 6 : preset == .d14 ? 13 : 29
            let s = cal.startOfDay(for: cal.date(byAdding: .day, value: -days, to: now) ?? now)
            return (Int64(s.timeIntervalSince1970), end)
        case .custom:
            let s = customStart.map { Int64($0.timeIntervalSince1970) } ?? (end - 86400)
            let e = liveEnd ? end : (customEnd.map { Int64($0.timeIntervalSince1970) } ?? end)
            return (s, e)
        }
    }

    var triggerLabel: String {
        guard preset == .custom else { return preset.label }
        let f = DateFormatter(); f.dateFormat = "MM/dd"
        let s = customStart.map { f.string(from: $0) } ?? "?"
        let e = liveEnd ? "now" : (customEnd.map { f.string(from: $0) } ?? "?")
        return "\(s)–\(e)"
    }
}

// MARK: - 触发按钮 + 弹出层

struct DateRangePicker: View {
    @Binding var selection: RangeSelection
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(Theme.textDim)
                Text(selection.triggerLabel).font(.system(size: 13)).foregroundStyle(Theme.textMain).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(width: 108, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(selection.preset == .custom ? Theme.accent : Theme.track.opacity(0.6), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            DateRangePopover(selection: $selection, open: $open).frame(width: 600)
        }
    }
}

// MARK: - 弹出内容

struct DateRangePopover: View {
    @Binding var selection: RangeSelection
    @Binding var open: Bool

    enum Field { case start, end }
    @State private var activeField: Field = .start
    @State private var draftStart = Date()
    @State private var draftEnd = Date()
    @State private var liveEnd = false
    @State private var displayMonth = Date()
    @State private var errorText: String?

    private let cal = Calendar.current
    private let presets: [RangePreset] = [.today, .d1, .d7, .d14, .d30]
    private let liveTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            presetRow
            Divider().overlay(Theme.track.opacity(0.4))
            HStack(alignment: .top, spacing: 12) {
                fieldsColumn.frame(width: 250)
                calendarColumn
            }
        }
        .padding(12)
        .frame(width: 600)
        .background(Theme.card)
        .onAppear(perform: initDraft)
        .onReceive(liveTimer) { _ in if liveEnd { draftEnd = Date() } }
    }

    private func initDraft() {
        let (s, e) = selection.resolve()
        draftStart = Date(timeIntervalSince1970: TimeInterval(s))
        draftEnd = Date(timeIntervalSince1970: TimeInterval(e))
        liveEnd = selection.preset == .custom ? selection.liveEnd : false
        displayMonth = cal.date(from: cal.dateComponents([.year, .month], from: draftStart)) ?? draftStart
        activeField = .start
        errorText = nil
    }

    // ── preset 快捷键 ──
    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(presets) { p in
                Button {
                    selection = RangeSelection(preset: p)
                    open = false
                } label: {
                    Text(p.label).font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(presetBg(p))
                        .foregroundStyle(selection.preset == p ? .white : Theme.textMain)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
    private func presetBg(_ p: RangePreset) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(selection.preset == p ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selection.preset == p ? Color.clear : Theme.track.opacity(0.6), lineWidth: 1))
    }

    // ── 左：起止时间 ──
    private var fieldsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Supports both date and time").font(.system(size: 12)).foregroundStyle(Theme.textDim)
            fieldCard(.start)
            fieldCard(.end)
            Toggle(isOn: Binding(get: { liveEnd }, set: { v in
                liveEnd = v
                if v { draftEnd = Date(); activeField = .start }
            })) {
                Text("End time follows current time").font(.system(size: 12)).foregroundStyle(Theme.textDim)
            }
            .toggleStyle(.checkbox)

            if let e = errorText {
                Text(e).font(.system(size: 12)).foregroundStyle(Theme.cost)
            }
            HStack(spacing: 8) {
                Button("Cancel") { open = false }.buttonStyle(.plain)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                    .foregroundStyle(Theme.textMain).font(.system(size: 13))
                Button(action: apply) { Text("Confirm").frame(maxWidth: .infinity) }
                    .buttonStyle(.plain).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                    .foregroundStyle(.white).font(.system(size: 13, weight: .medium))
            }
            .padding(.top, 2)
        }
    }

    private func fieldCard(_ field: Field) -> some View {
        let isActive = activeField == field
        let isEndLive = field == .end && liveEnd
        let binding = field == .start ? $draftStart : $draftEnd
        return VStack(alignment: .leading, spacing: 6) {
            Text(field == .start ? "START TIME" : "END TIME")
                .font(.system(size: 11, weight: .medium)).tracking(0.5)
                .foregroundStyle(Theme.textDim)
            HStack(spacing: 8) {
                Text(dateText(binding.wrappedValue)).font(.system(size: 15))
                    .foregroundStyle(Theme.textMain)
                Spacer()
                DatePicker("", selection: binding, displayedComponents: .hourAndMinute)
                    .labelsHidden().datePickerStyle(.field)
                    .disabled(isEndLive)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isActive && !isEndLive ? Theme.accent.opacity(0.05) : Theme.muted.opacity(0.3))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(isActive && !isEndLive ? Theme.accent : Theme.track.opacity(0.5),
                            lineWidth: isActive && !isEndLive ? 1.5 : 1))
        )
        .opacity(isEndLive ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !isEndLive { activeField = field } }
    }

    // ── 右：日历 ──
    private var calendarColumn: some View {
        VStack(spacing: 6) {
            HStack {
                navButton("chevron.left") { shiftMonth(-1) }
                Spacer()
                Button(action: goToday) {
                    Text(monthTitle).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textMain)
                }.buttonStyle(.plain)
                Spacer()
                navButton("chevron.right") { shiftMonth(1) }
            }
            HStack(spacing: 0) {
                ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, w in
                    Text(w).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity)
                }
            }
            let cols = Array(repeating: GridItem(.flexible(), spacing: 1), count: 7)
            LazyVGrid(columns: cols, spacing: 1) {
                ForEach(calendarDays, id: \.self) { day in dayCell(day) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Theme.muted.opacity(0.3))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.track.opacity(0.5), lineWidth: 1))
        )
    }

    private func navButton(_ sym: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: sym).font(.system(size: 12)).foregroundStyle(Theme.textDim)
                .frame(width: 26, height: 26)
        }.buttonStyle(.plain)
    }

    private func dayCell(_ day: Date) -> some View {
        let isCurrentMonth = cal.isDate(day, equalTo: displayMonth, toGranularity: .month)
        let isToday = cal.isDateInToday(day)
        let isStart = cal.isDate(day, inSameDayAs: draftStart)
        let isEnd = cal.isDate(day, inSameDayAs: draftEnd)
        let isEndpoint = isStart || isEnd
        let d0 = cal.startOfDay(for: day)
        let inRange = d0 >= cal.startOfDay(for: draftStart) && d0 <= cal.startOfDay(for: draftEnd)

        return Button { pickDay(day) } label: {
            Text("\(cal.component(.day, from: day))")
                .font(.system(size: 12, weight: isEndpoint ? .medium : .regular))
                .frame(maxWidth: .infinity, minHeight: 26)
                .foregroundStyle(
                    isEndpoint ? Color.white :
                    !isCurrentMonth ? Theme.textDim.opacity(0.3) :
                    inRange ? Theme.accent : Theme.textMain
                )
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(
                        isEndpoint ? AnyShapeStyle(Theme.accent) :
                        inRange ? AnyShapeStyle(Theme.accent.opacity(0.10)) : AnyShapeStyle(Color.clear)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(isToday && !isEndpoint ? Theme.accent.opacity(0.4) : Color.clear, lineWidth: 1))
                )
        }.buttonStyle(.plain)
    }

    // ── 逻辑 ──
    private var monthTitle: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "LLLL yyyy"
        return f.string(from: displayMonth)
    }
    private var weekdayLabels: [String] { ["S", "M", "T", "W", "T", "F", "S"] }

    private var calendarDays: [Date] {
        let comps = cal.dateComponents([.year, .month], from: displayMonth)
        guard let first = cal.date(from: comps) else { return [] }
        let weekday = cal.component(.weekday, from: first) - 1   // 0=Sunday
        let gridStart = cal.date(byAdding: .day, value: -weekday, to: first) ?? first
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private func dateText(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MM/dd/yyyy"; return f.string(from: d)
    }

    private func shiftMonth(_ delta: Int) {
        displayMonth = cal.date(byAdding: .month, value: delta, to: displayMonth) ?? displayMonth
    }
    private func goToday() {
        displayMonth = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
    }

    private func setDateKeepTime(_ ts: Date, _ day: Date) -> Date {
        let t = cal.dateComponents([.hour, .minute], from: ts)
        var dc = cal.dateComponents([.year, .month, .day], from: day)
        dc.hour = t.hour; dc.minute = t.minute
        return cal.date(from: dc) ?? ts
    }

    private func pickDay(_ day: Date) {
        errorText = nil
        if liveEnd {
            draftStart = setDateKeepTime(draftStart, day); syncMonth(day); return
        }
        if activeField == .start {
            let next = setDateKeepTime(draftStart, day)
            draftStart = next
            if next > draftEnd { draftEnd = next }
            activeField = .end
        } else {
            let next = setDateKeepTime(draftEnd, day)
            if next < draftStart { draftStart = next; activeField = .end }
            else { draftEnd = next }
        }
        syncMonth(day)
    }
    private func syncMonth(_ day: Date) {
        if !cal.isDate(day, equalTo: displayMonth, toGranularity: .month) {
            displayMonth = cal.date(from: cal.dateComponents([.year, .month], from: day)) ?? day
        }
    }

    private func apply() {
        if draftStart > draftEnd { errorText = "Start time cannot be after end time"; return }
        selection = RangeSelection(preset: .custom, customStart: draftStart, customEnd: draftEnd, liveEnd: liveEnd)
        open = false
    }
}
