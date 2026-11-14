//! A caller's stop flag, below every search that reads it: Myers, the
//! histogram and patience searches and the diff that drives them.
const aegis = @import("aegis");

/// Whether a caller asked a diff to stop.
pub const Raised = enum(u8) { no, yes };
/// A caller's stop flag: raised once (`store(.yes, ...)`), read by the search once
/// per work unit and once per region.
pub const Stop = aegis.Atomic(Raised);
