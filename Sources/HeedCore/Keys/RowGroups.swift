/// `{` and `}`: lists move by group as vim moves by paragraph. A group is a run of rows with the same key (a sidebar
/// group, a repo, a day).
public enum RowGroups {
    /// The first row of the next group, nil on the last group.
    public static func next(_ keys: [String], from index: Int) -> Int? {
        guard keys.indices.contains(index) else { return nil }
        return keys.indices.first { $0 > index && keys[$0] != keys[index] }
    }

    /// The first row of this group, or of the previous one when already there.
    public static func previous(_ keys: [String], from index: Int) -> Int? {
        guard keys.indices.contains(index) else { return nil }
        let start = groupStart(keys, index)
        if start < index { return start }
        return start > 0 ? groupStart(keys, start - 1) : nil
    }

    private static func groupStart(_ keys: [String], _ index: Int) -> Int {
        var start = index
        while start > 0, keys[start - 1] == keys[index] {
            start -= 1
        }
        return start
    }
}
