use warp_controller::state::{
    EngineStatus, Observation, PolicyAction, ProcessStatus, RuntimeReadiness, plan_policy,
    runtime_readiness,
};

#[test]
fn runtime_ready_requires_live_process_ready_status_and_existing_interface() {
    assert_eq!(
        runtime_readiness(
            ProcessStatus::Present,
            EngineStatus::Ready {
                iface: "z2ktun0".into()
            },
            Some(true)
        ),
        RuntimeReadiness::Ready {
            iface: "z2ktun0".into()
        }
    );
}

#[test]
fn missing_process_or_interface_is_known_not_ready() {
    let status = EngineStatus::Ready {
        iface: "z2ktun0".into(),
    };
    assert_eq!(
        runtime_readiness(ProcessStatus::Absent, status.clone(), Some(true)),
        RuntimeReadiness::NotReady
    );
    assert_eq!(
        runtime_readiness(ProcessStatus::Present, status, Some(false)),
        RuntimeReadiness::NotReady
    );
}

#[test]
fn transient_process_status_or_link_read_errors_are_unreadable() {
    assert_eq!(
        runtime_readiness(ProcessStatus::Present, EngineStatus::Unreadable, Some(true)),
        RuntimeReadiness::Unreadable
    );
    assert_eq!(
        runtime_readiness(
            ProcessStatus::Present,
            EngineStatus::Ready {
                iface: "z2ktun0".into()
            },
            None
        ),
        RuntimeReadiness::Unreadable
    );
}

#[test]
fn unreadable_status_defers_without_dropping_policy() {
    assert_eq!(
        plan_policy(
            Observation::Known(true),
            Observation::Unreadable,
            Observation::Known(true)
        ),
        PolicyAction::Defer
    );
}

#[test]
fn proven_unready_engine_removes_existing_policy() {
    assert_eq!(
        plan_policy(
            Observation::Known(true),
            Observation::Known(false),
            Observation::Known(true)
        ),
        PolicyAction::RemovePolicy
    );
}

#[test]
fn healthy_policy_is_a_noop() {
    assert_eq!(
        plan_policy(
            Observation::Known(true),
            Observation::Known(true),
            Observation::Known(true)
        ),
        PolicyAction::Noop
    );
}

#[test]
fn ready_engine_applies_missing_policy() {
    assert_eq!(
        plan_policy(
            Observation::Known(true),
            Observation::Known(true),
            Observation::Known(false)
        ),
        PolicyAction::ApplyPolicy
    );
}

#[test]
fn disabled_intent_removes_policy_even_if_engine_is_ready() {
    assert_eq!(
        plan_policy(
            Observation::Known(false),
            Observation::Known(true),
            Observation::Known(true)
        ),
        PolicyAction::RemovePolicy
    );
}

#[test]
fn explicit_disable_does_not_depend_on_a_readable_daemon_status() {
    assert_eq!(
        plan_policy(
            Observation::Known(false),
            Observation::Unreadable,
            Observation::Known(true)
        ),
        PolicyAction::RemovePolicy
    );
}

#[test]
fn already_absent_policy_is_not_mutated() {
    assert_eq!(
        plan_policy(
            Observation::Known(false),
            Observation::Known(false),
            Observation::Known(false)
        ),
        PolicyAction::Noop
    );
}
