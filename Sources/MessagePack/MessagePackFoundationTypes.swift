import Foundation

/// The identifiers of the Foundation types the coders represent natively.
///
/// Cached, as comparing a type with `Date.self` calls Foundation's metadata
/// accessor every time: with every struct passing these checks on its way to
/// its own conformance, those calls showed up in profiles. Loading all of
/// them from one static value costs a single lazy-initialization check.
struct MessagePackFoundationTypes {
    static let shared = Self()

    let date = ObjectIdentifier(Date.self)
    let data = ObjectIdentifier(Data.self)
}
