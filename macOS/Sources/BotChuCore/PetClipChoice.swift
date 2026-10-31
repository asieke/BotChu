import Foundation

/// What a pet's video does when its bot asks for a clip (#29): a one-shot reaction, such as the
/// greeting, finishes before idle takes over, and the clip asked for last isn't played again when
/// the view refreshes. A new activity or a different pet takes over at once.
public enum PetClipChoice: Equatable, Sendable {
    /// Nothing changes: this clip is the one asked for last.
    case unchanged
    /// The still becomes this clip's, and the video playing goes on: it is this clip already, or a
    /// reaction that finishes before idle (including the time its video takes to load).
    case keepPlaying
    /// This clip starts.
    case play

    /// - Parameters:
    ///   - samePackage: whether it is the pet already showing.
    ///   - requested: the clip asked for last.
    ///   - current: the clip playing, perhaps still loading, and whether it is a reaction (plays once).
    public static func choose(_ clipID: String, samePackage: Bool, requested: String?,
                              current: (clipID: String, isReaction: Bool)?) -> PetClipChoice {
        guard !samePackage || requested != clipID else { return .unchanged }
        guard samePackage, let current else { return .play }
        if current.clipID == clipID { return .keepPlaying }
        if clipID == "idle", current.isReaction { return .keepPlaying }
        return .play
    }
}
