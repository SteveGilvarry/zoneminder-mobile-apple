import Foundation
import Testing
@testable import ZmMobileCore

@Test func tokenResponseAcceptsExpireInAndExpiresIn() throws {
    let decoder = JSONDecoder()
    let expireIn = try decoder.decode(TokenResponse.self, from: Data(#"{"access_token":"a","refresh_token":"r","token_type":"Bearer","expire_in":120}"#.utf8))
    #expect(expireIn.expiresIn == 120)

    let expiresIn = try decoder.decode(TokenResponse.self, from: Data(#"{"access_token":"a","refresh_token":"r","token_type":"Bearer","expires_in":90}"#.utf8))
    #expect(expiresIn.expiresIn == 90)
}
