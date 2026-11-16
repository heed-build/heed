import Foundation

/// Which fetch a result belongs to: a load hands one out when it starts, and only the result carrying the latest is
/// taken. A fetch that was replaced (or cancelled) finishing late changes nothing.
public struct LoadToken: Hashable, Sendable {
    let id = UUID()

    public init() {}
}

/// Where something fetched stands: never asked for, loading (with what was there before, which stays on screen),
/// loaded, or failed (with what was there before). A result or failure is applied only when its token is the one
/// the current load started with, so a stale fetch can neither overwrite a newer one nor end it.
public enum Load<Value> {
    case idle
    case loading(LoadToken, stale: Value?)
    case loaded(Value)
    case failed(String, stale: Value?)

    /// What there is to show: the loaded value, or the one kept while loading again or after a failure.
    public var value: Value? {
        switch self {
        case .idle: nil
        case let .loading(_, stale): stale
        case let .loaded(value): value
        case let .failed(_, stale): stale
        }
    }

    public var isLoading: Bool {
        if case .loading = self { true } else { false }
    }

    /// Why the last load failed; nil once another starts.
    public var error: String? {
        if case let .failed(error, _) = self { error } else { nil }
    }

    /// The token of the load running now.
    public var token: LoadToken? {
        if case let .loading(token, _) = self { token } else { nil }
    }

    /// Starts a load, replacing any running one (whose result will be ignored): what there was stays as stale, and
    /// an earlier failure is forgotten.
    @discardableResult
    public mutating func start(_ token: LoadToken = LoadToken()) -> LoadToken {
        self = .loading(token, stale: value)
        return token
    }

    /// The load `token` finished with `value`. False (and nothing changes) when it is not the current load.
    @discardableResult
    public mutating func finish(_ token: LoadToken, with value: Value) -> Bool {
        guard self.token == token else { return false }
        self = .loaded(value)
        return true
    }

    /// The load `token` failed. False (and nothing changes) when it is not the current load.
    @discardableResult
    public mutating func fail(_ token: LoadToken, _ error: String) -> Bool {
        guard self.token == token else { return false }
        self = .failed(error, stale: value)
        return true
    }

    /// The load `token` was given up without a result (cancelled): back to what there was. False when it is not the
    /// current load.
    @discardableResult
    public mutating func abandon(_ token: LoadToken) -> Bool {
        guard self.token == token else { return false }
        self = value.map { .loaded($0) } ?? .idle
        return true
    }
}

extension Load: Equatable where Value: Equatable {}
extension Load: Sendable where Value: Sendable {}
