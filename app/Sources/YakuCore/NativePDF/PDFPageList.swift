import Foundation

/// The page list the user gives (`--pdf-pages`): 1-based numbers and ranges
/// such as "1,3-5". Returns 0-based indices, or nil when nothing valid remains.
public enum PDFPageList {
    public static func parse(_ text: String) -> Set<Int>? {
        var pages = Set<Int>()
        for part in text.split(separator: ",") {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
                .map { Int($0.trimmingCharacters(in: .whitespaces)) }
            switch bounds.count {
            case 1:
                if let page = bounds[0], page >= 1 { pages.insert(page - 1) }
            case 2:
                if let first = bounds[0], let last = bounds[1], first >= 1, last >= first {
                    pages.formUnion((first - 1)...(last - 1))
                }
            default:
                continue
            }
        }
        return pages.isEmpty ? nil : pages
    }
}
