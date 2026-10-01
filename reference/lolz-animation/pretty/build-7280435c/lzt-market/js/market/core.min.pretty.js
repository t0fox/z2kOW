try {
  let e =
      typeof window < `u`
        ? window
        : typeof global < `u`
          ? global
          : typeof globalThis < `u`
            ? globalThis
            : typeof self < `u`
              ? self
              : {},
    t = new e.Error().stack;
  t &&
    ((e._sentryDebugIds = e._sentryDebugIds || {}),
    (e._sentryDebugIds[t] = `a2e1c51e-6796-41a8-836f-4d5dc5ac42ac`),
    (e._sentryDebugIdIdentifier = `sentry-dbid-a2e1c51e-6796-41a8-836f-4d5dc5ac42ac`));
} catch (e) {}
import {
  core_default as e,
  init_core as t,
} from "../assets/js/chunks/core-BLhDKL1T.js";
t();
