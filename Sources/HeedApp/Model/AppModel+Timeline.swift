import HeedCore

/// History's timeline (`history.timeline`): the glue its browser and view need from the model.
extension AppModel {
    /// The History entry of a timeline line's session: what `R` reopens from there.
    func timelineEntry(_ item: TimelineItem) -> HistoryEntry? {
        guard let id = item.session else { return nil }
        return history.first { $0.id == id }
    }
}
