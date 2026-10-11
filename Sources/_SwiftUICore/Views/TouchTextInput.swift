import Foundation

// iOS's text-input API (`keyboardType`, `textInputAutocapitalization`, `textContentType` with
// UIKit's types), on non-Apple platforms with soft keyboards (Android). UIKit's types are
// provided by name so unchanged iOS code compiles.
#if !canImport(ObjectiveC)
public enum UIKeyboardType: Int, Sendable {
    case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad, phonePad, namePhonePad, emailAddress, decimalPad, twitter, webSearch, asciiCapableNumberPad
    public static let alphabet = UIKeyboardType.asciiCapable
}

public struct UITextContentType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static let name = UITextContentType("name")
    public static let givenName = UITextContentType("givenName")
    public static let familyName = UITextContentType("familyName")
    public static let nickname = UITextContentType("nickname")
    public static let organizationName = UITextContentType("organizationName")
    public static let jobTitle = UITextContentType("jobTitle")
    public static let location = UITextContentType("location")
    public static let fullStreetAddress = UITextContentType("fullStreetAddress")
    public static let addressCity = UITextContentType("addressCity")
    public static let addressState = UITextContentType("addressState")
    public static let postalCode = UITextContentType("postalCode")
    public static let countryName = UITextContentType("countryName")
    public static let telephoneNumber = UITextContentType("telephoneNumber")
    public static let emailAddress = UITextContentType("emailAddress")
    public static let URL = UITextContentType("URL")
    public static let creditCardNumber = UITextContentType("creditCardNumber")
    public static let username = UITextContentType("username")
    public static let password = UITextContentType("password")
    public static let newPassword = UITextContentType("newPassword")
    public static let oneTimeCode = UITextContentType("oneTimeCode")
    public static let dateTime = UITextContentType("dateTime")
    public static let flightNumber = UITextContentType("flightNumber")
    public static let shipmentTrackingNumber = UITextContentType("shipmentTrackingNumber")
}

public struct TextInputAutocapitalization: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case never, words, sentences, characters }
    let kind: Kind
    public static let never = TextInputAutocapitalization(kind: .never)
    public static let words = TextInputAutocapitalization(kind: .words)
    public static let sentences = TextInputAutocapitalization(kind: .sentences)
    public static let characters = TextInputAutocapitalization(kind: .characters)
}

struct KeyboardTypeKey: EnvironmentKey { static let defaultValue = UIKeyboardType.default }
struct AutocapitalizationKey: EnvironmentKey { static let defaultValue: TextInputAutocapitalization? = nil }

extension EnvironmentValues {
    var keyboardType: UIKeyboardType {
        get { self[KeyboardTypeKey.self] }
        set { self[KeyboardTypeKey.self] = newValue }
    }
    var textInputAutocapitalization: TextInputAutocapitalization? {
        get { self[AutocapitalizationKey.self] }
        set { self[AutocapitalizationKey.self] = newValue }
    }
}

extension View {
    public func keyboardType(_ type: UIKeyboardType) -> some View { environment(\.keyboardType, type) }
    public func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> some View {
        environment(\.textInputAutocapitalization, autocapitalization)
    }
    public func textContentType(_ type: UITextContentType?) -> some View {
        environment(\._textContentType, type?.rawValue)
    }
}
#endif
