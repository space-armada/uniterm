import Foundation

/// An applet whose input belongs to a program running inside it, such as a terminal or a script
/// REPL. The host never sends it content from outside, and a script that tries gets an error.
///
/// The refusal is a property the applet declares. It holds even when the applet could also take a
/// source, so a later applet that adopts both is still refused.
@MainActor
public protocol InputOwning: Applet {}
