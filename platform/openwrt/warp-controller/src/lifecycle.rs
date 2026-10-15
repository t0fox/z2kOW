use crate::state::Observation;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ServiceIntent {
    Enable,
    Disable,
    Restart,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ServiceAction {
    Defer,
    None,
    Reload,
    Rebuild,
}

pub fn service_action(
    intent: ServiceIntent,
    was_enabled: bool,
    service_active: Observation<bool>,
    process_running: bool,
) -> ServiceAction {
    let service_active = match service_active {
        Observation::Known(active) => active,
        Observation::Unreadable => return ServiceAction::Defer,
    };
    if !service_active {
        return ServiceAction::None;
    }

    match intent {
        ServiceIntent::Enable if !was_enabled || !process_running => ServiceAction::Rebuild,
        ServiceIntent::Disable if process_running => ServiceAction::Rebuild,
        ServiceIntent::Enable | ServiceIntent::Disable => ServiceAction::Reload,
        ServiceIntent::Restart if was_enabled => ServiceAction::Rebuild,
        ServiceIntent::Restart => ServiceAction::None,
    }
}

#[cfg(test)]
mod tests {
    use super::{ServiceAction, ServiceIntent, service_action};
    use crate::state::Observation;

    #[test]
    fn service_action_preserves_enable_disable_restart_transitions() {
        let cases = [
            (
                ServiceIntent::Enable,
                false,
                Observation::Known(true),
                true,
                ServiceAction::Rebuild,
            ),
            (
                ServiceIntent::Enable,
                true,
                Observation::Known(true),
                true,
                ServiceAction::Reload,
            ),
            (
                ServiceIntent::Enable,
                true,
                Observation::Known(true),
                false,
                ServiceAction::Rebuild,
            ),
            (
                ServiceIntent::Enable,
                false,
                Observation::Known(false),
                true,
                ServiceAction::None,
            ),
            (
                ServiceIntent::Disable,
                true,
                Observation::Known(true),
                true,
                ServiceAction::Rebuild,
            ),
            (
                ServiceIntent::Disable,
                true,
                Observation::Known(true),
                false,
                ServiceAction::Reload,
            ),
            (
                ServiceIntent::Disable,
                true,
                Observation::Known(false),
                true,
                ServiceAction::None,
            ),
            (
                ServiceIntent::Restart,
                false,
                Observation::Known(true),
                true,
                ServiceAction::None,
            ),
            (
                ServiceIntent::Restart,
                true,
                Observation::Known(true),
                true,
                ServiceAction::Rebuild,
            ),
            (
                ServiceIntent::Restart,
                true,
                Observation::Known(false),
                true,
                ServiceAction::None,
            ),
        ];

        for (intent, was_enabled, service_active, process_running, expected) in cases {
            assert_eq!(
                service_action(intent, was_enabled, service_active, process_running),
                expected,
                "неверный переход для {intent:?}/{was_enabled}/{service_active:?}/{process_running}"
            );
        }
    }

    #[test]
    fn unreadable_service_state_defers_every_lifecycle_action() {
        for intent in [
            ServiceIntent::Enable,
            ServiceIntent::Disable,
            ServiceIntent::Restart,
        ] {
            assert_eq!(
                service_action(intent, true, Observation::Unreadable, true),
                ServiceAction::Defer
            );
        }
    }
}
