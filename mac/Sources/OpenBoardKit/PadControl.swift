import Foundation

/**
 Which physical control a binding belongs to, and how it was pressed.

 Shared vocabulary between the profile resolver and the settings editor: both key their
 lookups on the same pair, so a change made in the settings window is exactly the
 change the dispatcher reads. Defined once here rather than in either package, so
 neither has to wait for the other to compile.
 */
public enum PadControl: Hashable, Sendable {
    /// "ACT06"…"ACT12".
    case action(String)
    case joystick(Joystick.Direction)
    case encoderClick, encoderLong
}

public enum Gesture: String, Sendable {
    case tap, hold
}
