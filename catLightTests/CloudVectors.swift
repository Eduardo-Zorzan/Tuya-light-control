// Reference values computed with Tuya's documented HMAC-SHA256 signing scheme (as implemented by tinytuya 1.21.1). Do not edit by hand.
enum CloudVectors {
    static let tokenSign = "2F22077344FB9CCD62141F5F2B4EEF898D70D883F6182B12E395AD58E73B205E"
    static let tokenPayload =
        "clientid1234567890121700000000000GET\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n\n/v1.0/token?grant_type=1"
    static let bizSign = "59D0245612EE48709D18CF375F0AA4877195FA9D21E6007997406B501F180375"
    static let bizPayload =
        "clientid123456789012tok_abcdef01234567891700000000123GET\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n\n/v1.0/iot-01/associated-users/devices?last_row_key=&size=100"
    static let emptyBodySha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}
