# SwiftUICharts and Charts

`SwiftUICharts` is a subset of Apple's Swift Charts API, drawn with `Canvas`: line, area, bar, point and rule marks
with numeric, date or categorical values, explicit scales and simple axes. Off Apple platforms the `Charts` product
re-exports it under Apple's module name, so code that writes `import Charts` builds unchanged.

It covers simple charts. Some modifiers are accepted and have no effect yet: `symbol`, `symbolSize`, `annotation`,
`cornerRadius`, `chartLegend`, `chartPlotStyle`, and the details of axis marks (grid lines, ticks, value labels,
`stride(by:)`).

## Getting started

Off Apple platforms (see [SwiftUI](SwiftUI.md#adding-the-package) for the conditional dependency):

```swift
.package(url: "https://github.com/v57/SwiftUI.git", branch: "main")
// in the target:
.product(name: "Charts", package: "SwiftUI")
```

With this SwiftUI on macOS too, depend on `SwiftUICharts` instead (`Charts` exists only off Apple platforms) and
`import SwiftUICharts`.

```swift
import Charts
import SwiftUI

struct Sample: Identifiable {
    let id = UUID()
    let day: Int
    let value: Double
}

struct UsageChart: View {
    let samples: [Sample]

    var body: some View {
        Chart(samples) { sample in
            LineMark(x: .value("Day", sample.day), y: .value("Value", sample.value))
        }
        .chartYScale(domain: 0...100)
        .frame(height: 200)
    }
}
```

## Main API

- `Chart { ... }`, `Chart(data) { element in ... }`, `Chart(data, id:) { ... }`: the chart view, with a
  `ChartContentBuilder` (conditions and `ForEach` work as in views).
- Marks: `LineMark(x:y:)` and `LineMark(x:y:series:)`, `AreaMark(x:y:)` and `AreaMark(x:yStart:yEnd:)`,
  `BarMark(x:y:)` and `BarMark(x:y:width:)`, `PointMark(x:y:)`, `RuleMark(x:)` and `RuleMark(y:)`.
- Values: `.value(_ label:_ value:)` (`PlottableValue`) for `Plottable` types: `Int`, `Double`, `Float`, `CGFloat`,
  `Date` (continuous) and `String` (categories).
- Mark styling: `foregroundStyle(_:)`, `foregroundStyle(by:)` (one color per series), `interpolationMethod(_:)`,
  `lineStyle(_:)`, `opacity(_:)`.
- Axes and scales: `chartXAxis` / `chartYAxis` (with `AxisMarks`, or a `Visibility`), `chartXScale(domain:)` /
  `chartYScale(domain:)` with a `ClosedRange<Double>` or `ClosedRange<Int>`.

## Platform notes

- `SwiftUICharts` builds wherever this SwiftUI does (macOS, Linux, Windows, Android).
- `Charts` exists only off Apple platforms. On macOS and iOS with Apple's SwiftUI, `import Charts` is Apple's
  framework.

## Testing

There are no chart-specific tests in this package. A chart is a view: host it in
[SwiftUIHeadless](SwiftUIHeadless.md)'s `TestHost` to check that it builds and updates.
