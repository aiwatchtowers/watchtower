import WatchtowerCore

/// What the tuning panel shows from the pane's report and the coach's
/// status: the figures line, the starters and whether the report is still
/// loading for the pane's period and agent.
struct TuningPanelInputs {
    var figures: TuningChatTexts.Figures?
    var starters: [ChatStarterPrompt]
    var loading: Bool

    static func make(
        overview: AgentReportOverview?,
        status: CoachStatus?,
        query: AgentAnalyticsCenter.Query
    ) -> Self {
        guard let overview, AgentAnalyticsFormat.period(of: overview) == query.period,
              AgentAnalyticsFormat.agent(of: overview) == query.agent else {
            return Self(figures: nil, starters: [], loading: true)
        }
        let cost = status?.metrics.taskCostUSD
        let perTask = cost?.known == true ? cost?.value : nil
        let previous = perTask == nil ? nil : cost?.previous
        var grew = false
        if let perTask, let previous { grew = perTask > previous }
        let figures = TuningChatTexts.Figures(
            days: query.period.rawValue, sessions: overview.totals.sessions,
            tasks: overview.tasks.count + (overview.tasksMore ?? 0), costUSD: overview.totals.costUSD,
            perTaskUSD: perTask, previousPerTaskUSD: previous
        )
        let starters = TuningChatTexts.starters(.init(costPerTaskGrew: grew, topHintFinding: overview.hints.first?.finding))
        return Self(figures: figures, starters: starters, loading: false)
    }
}
