/// Home-row hint labels: one letter each when they fit, else two letters for all, so no label is a prefix of another.
public enum HintLabels {
    public static let alphabet = Array("asdfghjklqwertyuiopzxcvbnm").map(String.init)

    public static func generate(count: Int) -> [String] {
        if count <= alphabet.count { return Array(alphabet.prefix(count)) }
        var labels: [String] = []
        for first in alphabet {
            for second in alphabet {
                labels.append(first + second)
                if labels.count == count { return labels }
            }
        }
        return labels
    }
}
