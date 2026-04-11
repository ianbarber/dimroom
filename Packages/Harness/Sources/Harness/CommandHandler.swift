import Foundation

/// Handler that processes harness commands and returns responses.
/// The app target conforms to this; tests can provide a mock.
public typealias CommandHandler = @Sendable (Command) async throws -> Response
