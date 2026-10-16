use crate::state::Observation;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ServiceIntent {
    Enable,
    Disable,
    Remove,
    Restart,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ServiceAction {
    Defer,
    None,
    Start,
    Stop,
    Reload,
    Restart,
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
    match intent {
        ServiceIntent::Enable if !service_active && process_running => ServiceAction::Defer,
        ServiceIntent::Enable if !service_active || !process_running => ServiceAction::Start,
        ServiceIntent::Enable if !was_enabled => ServiceAction::Restart,
        ServiceIntent::Enable => ServiceAction::Reload,
        ServiceIntent::Disable | ServiceIntent::Remove if service_active || process_running => {
            ServiceAction::Stop
        }
        ServiceIntent::Disable | ServiceIntent::Remove => ServiceAction::None,
        ServiceIntent::Restart if !was_enabled => ServiceAction::None,
        ServiceIntent::Restart if service_active => ServiceAction::Restart,
        ServiceIntent::Restart if process_running => ServiceAction::Defer,
        ServiceIntent::Restart => ServiceAction::Start,
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
                ServiceAction::Restart,
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
                ServiceAction::Start,
            ),
            (
                ServiceIntent::Enable,
                false,
                Observation::Known(false),
                false,
                ServiceAction::Start,
            ),
            (
                ServiceIntent::Enable,
                false,
                Observation::Known(false),
                true,
                ServiceAction::Defer,
            ),
            (
                ServiceIntent::Disable,
                true,
                Observation::Known(true),
                true,
                ServiceAction::Stop,
            ),
            (
                ServiceIntent::Disable,
                true,
                Observation::Known(true),
                false,
                ServiceAction::Stop,
            ),
            (
                ServiceIntent::Disable,
                true,
                Observation::Known(false),
                true,
                ServiceAction::Stop,
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
                ServiceAction::Restart,
            ),
            (
                ServiceIntent::Restart,
                true,
                Observation::Known(false),
                true,
                ServiceAction::Defer,
            ),
            (
                ServiceIntent::Restart,
                true,
                Observation::Known(false),
                false,
                ServiceAction::Start,
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
            ServiceIntent::Remove,
            ServiceIntent::Restart,
        ] {
            assert_eq!(
                service_action(intent, true, Observation::Unreadable, true),
                ServiceAction::Defer
            );
        }
    }
}
