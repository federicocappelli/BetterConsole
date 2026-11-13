/// A device whose logs can be streamed. Availability is tracked by `SessionRegistry`, not here.
public struct LogDevice: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable { case thisMac, physical, simulator }

    /// `"local"`, a physical device UDID, or a simulator UDID.
    public let id: String
    public let name: String
    public let kind: Kind
    /// e.g. "iPhone 18 Pro".
    public let model: String?
    public let osVersion: String?

    public init(id: String, name: String, kind: Kind, model: String? = nil, osVersion: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.model = model
        self.osVersion = osVersion
    }
}
