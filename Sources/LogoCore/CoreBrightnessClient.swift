import Foundation

/// Wrapper for CoreBrightness's private `BrightnessSystemClient`. Uses only `LEBacklightMode` and `LEPWMState`.
public final class CoreBrightnessClient {
    private let client: NSObject
    private typealias GetFn = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
    private typealias SetFn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Bool
    private let getImp: GetFn
    private let setImp: SetFn
    private let getSel = NSSelectorFromString("copyPropertyForKey:")
    private let setSel = NSSelectorFromString("setProperty:forKey:")

    public init() throws {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil else {
            throw LogoError.coreBrightnessUnavailable("cannot load CoreBrightness")
        }
        guard let cls = NSClassFromString("BrightnessSystemClient") as? NSObject.Type else {
            throw LogoError.coreBrightnessUnavailable("no BrightnessSystemClient class")
        }
        let c = cls.init()
        guard c.responds(to: getSel), c.responds(to: setSel) else {
            throw LogoError.coreBrightnessUnavailable("BrightnessSystemClient lacks copyPropertyForKey:/setProperty:forKey:")
        }
        client = c
        getImp = unsafeBitCast(c.method(for: getSel), to: GetFn.self)
        setImp = unsafeBitCast(c.method(for: setSel), to: SetFn.self)
    }

    /// `copyPropertyForKey:` returns a retained object (Cocoa "copy" rule).
    public func property(_ key: String) -> Any? {
        getImp(client, getSel, key as NSString)?.takeRetainedValue()
    }

    /// 0 = CoreBrightness keeps its hands off the logo (dark unless we drive it), 2 = follows the display.
    public var mode: Int? { (property("LEBacklightMode") as? NSNumber)?.intValue }

    public func setMode(_ mode: Int) throws {
        guard mode == 0 || mode == 2 else { throw LogoError.invalidArgument("LEBacklightMode must be 0 or 2") }
        guard setImp(client, setSel, NSNumber(value: mode), "LEBacklightMode" as NSString) else {
            throw LogoError.rejected("setProperty LEBacklightMode=\(mode) returned NO")
        }
    }

    public var leState: [String: Any]? { property("LEPWMState") as? [String: Any] }
}
