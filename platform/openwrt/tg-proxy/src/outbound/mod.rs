//! Прямой исходящий TCP connector с поддержкой SO_MARK на Linux.

mod connector;

pub use connector::{OutboundConnector, OutboundError};
