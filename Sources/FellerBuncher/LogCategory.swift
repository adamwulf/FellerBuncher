/// A destination-routing and wire-format category.
public struct LogCategory: Sendable, Hashable, ExpressibleByStringLiteral {
    public static let `default`: Self = "default"

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public init<Category: LogCategoryConvertible>(_ category: Category) {
        self.init(rawValue: category.rawValue)
    }
}

/// Adopt this protocol on an application's `String`-backed category enum.
public protocol LogCategoryConvertible: RawRepresentable, Sendable where RawValue == String {}

extension LogCategory: LogCategoryConvertible {}
