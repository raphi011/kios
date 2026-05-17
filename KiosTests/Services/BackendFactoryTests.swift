import Testing
import Foundation
import Core
@testable import Kios

// TODO: Task 13 — rewrite these tests against the new build(source:auth:…) API.
// All previous tests relied on the old build(auth:deviceID:deviceName:) signature
// and AuthStore methods (saveActiveProtocol, clear, save, saveKobo) that were
// removed in Task 2. New tests will construct a Source fixture and a
// TransientAuthStore (or MockAuthReading) instead.
@Suite("BackendFactory", .serialized)
struct BackendFactoryTests {}
