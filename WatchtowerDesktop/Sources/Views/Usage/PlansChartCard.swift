import DesignKit
import SwiftUI
import WatchtowerCore

struct PlansChartCard: View {
    let provider: PlansScreenProvider
    let period: PlansPeriod
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack {
                Circle().fill(color).frame(width: IconSize.stateDot, height: IconSize.stateDot)
                Text(provider.presentation.title).font(.callout.weight(.medium))
                Spacer()
                if let item = provider.selected(period) { Text(item.percent).font(.callout.weight(.semibold)).monospacedDigit() }
            }
            if let item = provider.selected(period) {
                if let start = item.windowStart, let reset = provider.reset(for: item), reset > start, !item.history.isEmpty {
                    HStack(spacing: Spacing.regular) {
                        PlansUsagePlot(item: item, start: start, reset: reset, now: now, color: color)
                            .frame(height: PlansLayout.chartHeight)
                        VStack {
                            Text(PlansScreenCopy.axes[0]); Spacer()
                            Text(PlansScreenCopy.axes[1]); Spacer()
                            Text(PlansScreenCopy.axes[2])
                        }.font(.caption2).foregroundStyle(.tertiary)
                    }
                    HStack {
                        Text(PlansScreenCopy.date(start))
                        Spacer()
                        Text(PlansScreenCopy.resetDate(reset))
                    }.font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(PlansScreenCopy.unavailable)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: PlansLayout.chartHeight)
                }
                Label(PlansScreenCopy.chartCaption(item),
                      systemImage: plansForecastIcon(item))
                    .font(.caption).foregroundStyle(plansForecastColor(item))
            } else {
                Text(provider.presentation.limits.isEmpty ? provider.presentation.summary : PlansScreenCopy.missingWindow(period))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: PlansLayout.chartHeight)
            }
        }.padding(Spacing.page).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private var color: Color { Tone.status(provider.id.subscription.tint) }
}

/// Only maps published points to display coordinates. It never estimates a rate or endpoint.
struct PlansUsagePlot: View {
    let item: PlansLimitPresentation
    let start: Date
    let reset: Date
    let now: Date
    let color: Color

    var body: some View {
        Canvas { context, size in
            let inset = PlansLayout.chartInset
            func point(_ date: Date, _ percent: Double) -> CGPoint {
                CGPoint(x: inset + (size.width - 2 * inset) * date.timeIntervalSince(start) / reset.timeIntervalSince(start),
                        y: inset + (size.height - 2 * inset) * (1 - percent / 100))
            }
            for fraction in [0.0, 0.5, 1.0] {
                var grid = Path()
                let y = inset + (size.height - 2 * inset) * fraction
                grid.move(to: CGPoint(x: inset, y: y)); grid.addLine(to: CGPoint(x: size.width - inset, y: y))
                context.stroke(grid, with: .color(Fill.hover), lineWidth: Stroke.hairline)
            }
            let current = min(reset, max(start, now))
            let currentX = point(current, 0).x
            var nowRule = Path()
            nowRule.move(to: CGPoint(x: currentX, y: inset)); nowRule.addLine(to: CGPoint(x: currentX, y: size.height - inset))
            context.stroke(nowRule, with: .color(Tone.status("gray")), style: StrokeStyle(lineWidth: Stroke.hairline, dash: [2, 4]))
            context.draw(Text(PlansPresentation.chartNow).font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: currentX - Spacing.small, y: inset + Spacing.compact), anchor: .topTrailing)
            var resetRule = Path()
            resetRule.move(to: point(reset, 100)); resetRule.addLine(to: point(reset, 0))
            context.stroke(resetRule, with: .color(Tone.status("gray")), lineWidth: Stroke.hairline)
            var history = Path()
            for (index, sample) in item.history.enumerated() {
                let position = point(sample.takenAt, sample.percent)
                if index == 0 { history.move(to: position) } else { history.addLine(to: position) }
            }
            if let first = item.history.first, let last = item.history.last {
                var fill = history
                fill.addLine(to: point(last.takenAt, 0)); fill.addLine(to: point(first.takenAt, 0)); fill.closeSubpath()
                context.fill(fill, with: .color(color.opacity(Fill.cardOpacity)))
            }
            context.stroke(history, with: .color(color), lineWidth: Stroke.selection)
            if let line = item.line {
                let end = point(line.endAt, line.endPercent)
                var forecast = Path()
                forecast.move(to: point(line.startAt, line.startPercent)); forecast.addLine(to: end)
                let forecastColor = item.tone == .warning ? Tone.warning : color
                context.stroke(forecast, with: .color(forecastColor), style: StrokeStyle(lineWidth: Stroke.selection, dash: [5, 4]))
                context.fill(Path(ellipseIn: CGRect(x: end.x - Spacing.small, y: end.y - Spacing.small,
                                                    width: Spacing.regular, height: Spacing.regular)), with: .color(forecastColor))
            }
        }
        .accessibilityLabel(item.forecast)
    }
}
