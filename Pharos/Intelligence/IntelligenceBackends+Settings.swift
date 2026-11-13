import Foundation

// Which backend answers, from the settings. Kept out of
// IntelligenceBackend.swift because it reaches `AppStateManager` and the
// core, which the standalone harnesses do not compile.
extension IntelligenceBackends {

    /// The endpoint backend made for the settings it was made from. Kept
    /// while those settings stand, so what one request learned about the
    /// endpoint (which way of asking for JSON it takes) serves the next.
    private static var made: (settings: IntelligenceEndpointSettings, backend: IntelligenceBackend)?

    /// Make `current`, and the name the user is shown for it
    /// (`IntelligenceSource.current`), follow Settings ▸ Intelligence.
    /// Called once, at launch.
    static func followSettings() {
        IntelligenceSource.current = {
            let settings = AppStateManager.shared.settings.intelligence
            return IntelligenceSource(
                usesEndpoint: settings.provider == .endpoint,
                address: settings.endpoint.baseUrl, model: settings.endpoint.model)
        }
        endpoint = {
            let settings = AppStateManager.shared.settings.intelligence
            guard settings.provider == .endpoint else { return nil }
            if let made, made.settings == settings.endpoint { return made.backend }
            let backend = backend(for: settings.endpoint)
            made = (settings.endpoint, backend)
            return backend
        }
    }

    /// The backend for an endpoint as configured.
    ///
    /// `ModelAvailability` refuses a feature before it asks an endpoint that
    /// is not set up. Should a request arrive anyway, it fails with the
    /// reason; it is never handed to the on-device model, because the user
    /// chose a different one.
    static func backend(for endpoint: IntelligenceEndpointSettings) -> IntelligenceBackend {
        let contextSize = Int(endpoint.contextTokens)
        let model = endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let problem = ModelAvailability.endpointProblem(endpoint)
        if problem == nil, case .success(let base) = IntelligenceEndpoint.baseURL(from: endpoint.baseUrl) {
            return EndpointIntelligenceBackend(
                base: base, model: model, contextSize: contextSize,
                key: { PharosCore.intelligenceEndpointKey() })
        }
        let reason = problem ?? ModelAvailability.endpointNotSetUpReason
        return EndpointIntelligenceBackend(
            base: URL(fileURLWithPath: "/"), model: model, contextSize: contextSize, key: { nil },
            transport: { _ in throw IntelligenceEndpointError.notSetUp(reason) })
    }
}
