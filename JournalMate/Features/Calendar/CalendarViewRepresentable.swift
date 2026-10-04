import SwiftUI
import UIKit

/// `UICalendarView` の SwiftUI ラッパ。
/// SwiftUI の `DatePicker` では日付ごとの装飾が付けられないため、UIKit を直接使う。
struct CalendarViewRepresentable: UIViewRepresentable {

    /// "yyyy-MM-dd" → (件数, 最も多い PARA)
    var markers: [String: (count: Int, para: Para)]
    @Binding var selectedDate: Date
    /// 表示月が変わったときに呼ばれる。呼び出し側はその月の markers を取り直す。
    var onVisibleMonthChange: (DateComponents) -> Void

    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        view.calendar = Calendar(identifier: .gregorian)
        view.locale = Locale.current
        view.fontDesign = .default
        view.delegate = context.coordinator

        let selection = UICalendarSelectionSingleDate(delegate: context.coordinator)
        selection.selectedDate = context.coordinator.components(for: selectedDate)
        context.coordinator.appliedDate = selectedDate
        view.selectionBehavior = selection

        // 高さを内容なりに決めさせる。Form / VStack の中で潰れないように。
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: UICalendarView, context: Context) {
        let coordinator = context.coordinator
        let changedDays = coordinator.apply(markers: markers)
        coordinator.parent = self

        // アプリの側から日付が変わったときだけ選択を動かす。
        // markers の取り直しなどで呼ばれるたびに setSelected すると、めくった月が選択日の月へ戻される。
        // UICalendarView は選択日に暦やタイムゾーンを足して持つので、DateComponents 同士では比べない。
        if !coordinator.isApplied(selectedDate),
           let selection = view.selectionBehavior as? UICalendarSelectionSingleDate {
            coordinator.appliedDate = selectedDate
            selection.setSelected(coordinator.components(for: selectedDate), animated: true)
        }

        if !changedDays.isEmpty {
            view.reloadDecorations(forDateComponents: changedDays, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {

        var parent: CalendarViewRepresentable
        private var markers: [String: (count: Int, para: Para)] = [:]
        private let calendar = Calendar(identifier: .gregorian)
        /// 最後にカレンダーへ反映した選択日（カレンダーで押された日も含む）。
        var appliedDate: Date?

        init(parent: CalendarViewRepresentable) {
            self.parent = parent
            self.markers = parent.markers
        }

        func isApplied(_ date: Date) -> Bool {
            appliedDate.map { calendar.isDate($0, inSameDayAs: date) } ?? false
        }

        func components(for date: Date) -> DateComponents {
            calendar.dateComponents([.year, .month, .day], from: date)
        }

        /// 新しい markers を取り込み、装飾を貼り直すべき日付を返す。
        func apply(markers new: [String: (count: Int, para: Para)]) -> [DateComponents] {
            let changedKeys = Set(new.keys).symmetricDifference(Set(markers.keys))
                .union(new.filter { key, value in
                    guard let old = markers[key] else { return false }
                    return old.count != value.count || old.para != value.para
                }.keys)
            markers = new

            return changedKeys.compactMap { key in
                Format.dayKey.date(from: key).map(components(for:))
            }
        }

        // MARK: 装飾

        func calendarView(_ calendarView: UICalendarView,
                          decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            guard let date = calendar.date(from: dateComponents),
                  let marker = markers[Format.dayKey(for: date)] else { return nil }

            // 件数が増えるほどドットを大きく。PARA の色で「その日の重心」を示す。
            let size: UICalendarView.DecorationSize = marker.count >= 3 ? .large
                                                    : marker.count == 2 ? .medium : .small
            return .default(color: UIColor(marker.para.tint), size: size)
        }

        func calendarView(_ calendarView: UICalendarView,
                          didChangeVisibleDateComponentsFrom previous: DateComponents) {
            parent.onVisibleMonthChange(calendarView.visibleDateComponents)
        }

        // MARK: 選択

        func dateSelection(_ selection: UICalendarSelectionSingleDate,
                           didSelectDate dateComponents: DateComponents?) {
            guard let dateComponents, let date = calendar.date(from: dateComponents) else { return }
            appliedDate = date
            parent.selectedDate = date
        }
    }
}
