import Foundation

enum AppConfigError: Error, LocalizedError {
    case missingConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let key):
            return "Missing \(key) in app configuration"
        }
    }
}

enum AppConfig {
    static func value(for key: String) throws -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              !value.hasPrefix("$(") else {
            throw AppConfigError.missingConfiguration(key)
        }
        return value
    }
}
