use crate::state::{EngineStatus, Observation, ProcessStatus, RuntimeReadiness, runtime_readiness};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HealthAction {
    Defer,
    Disabled,
    BinaryMissing,
    DeviceMissing,
    ProcessAbsent,
    NotReady,
    Ready,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BootAction {
    Defer,
    Skip,
    Start,
}

pub fn ready_since(
    process: ProcessStatus,
    engine: EngineStatus,
    iface_present: Option<bool>,
    status_modified: Option<u64>,
    started_at: u64,
) -> RuntimeReadiness {
    match process {
        ProcessStatus::Absent => return RuntimeReadiness::NotReady,
        ProcessStatus::Unreadable => return RuntimeReadiness::Unreadable,
        ProcessStatus::Present => {}
    }
    match engine {
        EngineStatus::NotReady => RuntimeReadiness::NotReady,
        EngineStatus::Unreadable => RuntimeReadiness::Unreadable,
        EngineStatus::Ready { .. } => match status_modified {
            Some(modified) if modified >= started_at => {
                runtime_readiness(process, engine, iface_present)
            }
            Some(_) => RuntimeReadiness::NotReady,
            None => RuntimeReadiness::Unreadable,
        },
    }
}

pub struct HealthObservations {
    pub config_enabled: Observation<bool>,
    pub feature_enabled: Observation<bool>,
    pub binary_present: Observation<bool>,
    pub device_present: Observation<bool>,
    pub process: ProcessStatus,
    pub engine: EngineStatus,
    pub iface_present: Option<bool>,
}

pub fn plan_boot(
    config_enabled: Observation<bool>,
    feature_enabled: Observation<bool>,
    binary_present: Observation<bool>,
    device_present: Observation<bool>,
) -> BootAction {
    for observation in [
        config_enabled,
        feature_enabled,
        binary_present,
        device_present,
    ] {
        match observation {
            Observation::Unreadable => return BootAction::Defer,
            Observation::Known(false) => return BootAction::Skip,
            Observation::Known(true) => {}
        }
    }
    BootAction::Start
}

pub fn plan(observations: HealthObservations) -> HealthAction {
    match observations.config_enabled {
        Observation::Unreadable => return HealthAction::Defer,
        Observation::Known(false) => return HealthAction::Disabled,
        Observation::Known(true) => {}
    }
    match observations.feature_enabled {
        Observation::Unreadable => return HealthAction::Defer,
        Observation::Known(false) => return HealthAction::Disabled,
        Observation::Known(true) => {}
    }
    match observations.binary_present {
        Observation::Unreadable => return HealthAction::Defer,
        Observation::Known(false) => return HealthAction::BinaryMissing,
        Observation::Known(true) => {}
    }
    match observations.device_present {
        Observation::Unreadable => return HealthAction::Defer,
        Observation::Known(false) => return HealthAction::DeviceMissing,
        Observation::Known(true) => {}
    }
    match observations.process {
        ProcessStatus::Unreadable => return HealthAction::Defer,
        ProcessStatus::Absent => return HealthAction::ProcessAbsent,
        ProcessStatus::Present => {}
    }
    match observations.engine {
        EngineStatus::Unreadable => HealthAction::Defer,
        EngineStatus::NotReady => HealthAction::NotReady,
        EngineStatus::Ready { .. } => match observations.iface_present {
            Some(true) => HealthAction::Ready,
            Some(false) => HealthAction::NotReady,
            None => HealthAction::Defer,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ready_inputs() -> HealthObservations {
        HealthObservations {
            config_enabled: Observation::Known(true),
            feature_enabled: Observation::Known(true),
            binary_present: Observation::Known(true),
            device_present: Observation::Known(true),
            process: ProcessStatus::Present,
            engine: EngineStatus::Ready {
                iface: "z2ktun0".into(),
            },
            iface_present: Some(true),
        }
    }

    #[test]
    fn healthy_state_is_ready() {
        assert_eq!(plan(ready_inputs()), HealthAction::Ready);
    }

    #[test]
    fn unreadable_observations_defer_without_disabling_policy() {
        let mut inputs = ready_inputs();
        inputs.config_enabled = Observation::Unreadable;
        assert_eq!(plan(inputs), HealthAction::Defer);

        let mut inputs = ready_inputs();
        inputs.process = ProcessStatus::Unreadable;
        assert_eq!(plan(inputs), HealthAction::Defer);

        let mut inputs = ready_inputs();
        inputs.engine = EngineStatus::Unreadable;
        assert_eq!(plan(inputs), HealthAction::Defer);
    }

    #[test]
    fn explicit_disable_precedes_unreadable_feature_state() {
        let mut inputs = ready_inputs();
        inputs.config_enabled = Observation::Known(false);
        inputs.feature_enabled = Observation::Unreadable;
        assert_eq!(plan(inputs), HealthAction::Disabled);
    }

    #[test]
    fn missing_binary_device_and_process_remain_distinct_states() {
        let mut inputs = ready_inputs();
        inputs.binary_present = Observation::Known(false);
        assert_eq!(plan(inputs), HealthAction::BinaryMissing);

        let mut inputs = ready_inputs();
        inputs.device_present = Observation::Known(false);
        assert_eq!(plan(inputs), HealthAction::DeviceMissing);

        let mut inputs = ready_inputs();
        inputs.process = ProcessStatus::Absent;
        assert_eq!(plan(inputs), HealthAction::ProcessAbsent);
    }

    #[test]
    fn live_unready_engine_keeps_the_probe_only_path() {
        let mut inputs = ready_inputs();
        inputs.engine = EngineStatus::NotReady;
        assert_eq!(plan(inputs), HealthAction::NotReady);

        let mut inputs = ready_inputs();
        inputs.iface_present = Some(false);
        assert_eq!(plan(inputs), HealthAction::NotReady);
    }

    #[test]
    fn ready_wait_requires_fresh_status_and_defers_unreadable_observations() {
        let ready = ready_inputs();
        assert_eq!(
            ready_since(
                ready.process,
                ready.engine.clone(),
                ready.iface_present,
                Some(100),
                100,
            ),
            RuntimeReadiness::Ready {
                iface: "z2ktun0".into()
            }
        );
        assert_eq!(
            ready_since(
                ready.process,
                ready.engine.clone(),
                ready.iface_present,
                Some(99),
                100,
            ),
            RuntimeReadiness::NotReady
        );
        assert_eq!(
            ready_since(ready.process, ready.engine, ready.iface_present, None, 100,),
            RuntimeReadiness::Unreadable
        );
    }

    #[test]
    fn boot_plan_requires_all_enabled_inputs() {
        let yes = Observation::Known(true);
        let no = Observation::Known(false);
        let unreadable = Observation::Unreadable;
        assert_eq!(plan_boot(yes, yes, yes, yes), BootAction::Start);
        assert_eq!(
            plan_boot(no, unreadable, unreadable, unreadable),
            BootAction::Skip
        );
        assert_eq!(plan_boot(yes, no, unreadable, unreadable), BootAction::Skip);
        assert_eq!(plan_boot(yes, yes, no, unreadable), BootAction::Skip);
        assert_eq!(plan_boot(yes, yes, yes, no), BootAction::Skip);
    }

    #[test]
    fn boot_plan_defers_when_an_enabled_input_cannot_be_read() {
        let yes = Observation::Known(true);
        let unreadable = Observation::Unreadable;
        assert_eq!(plan_boot(unreadable, yes, yes, yes), BootAction::Defer);
        assert_eq!(plan_boot(yes, unreadable, yes, yes), BootAction::Defer);
        assert_eq!(plan_boot(yes, yes, unreadable, yes), BootAction::Defer);
        assert_eq!(plan_boot(yes, yes, yes, unreadable), BootAction::Defer);
    }
}
