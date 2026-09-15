/// Lifecycle states for a tracked colony, mirroring BoT-SORT's
/// `tracker/basetrack.py` `TrackState`. Its `New` and `LongLost` states are
/// unused by the no-Re-ID orchestration this port implements (the reference
/// never transitions a track into `LongLost`, and `New` is only ever a
/// pre-`activate()` default that this port replaces with the `tracked` value
/// `STrack.activate` assigns immediately), so both are omitted.
enum TrackState { tracked, lost, removed }
