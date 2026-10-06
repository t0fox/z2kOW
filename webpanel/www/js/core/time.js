"use strict";

const MAX_EPOCH_SECONDS = 8640000000000;
const FUTURE_TOLERANCE_SECONDS = 5;

function epochSeconds(value) {
  const seconds = Number(value);
  return Number.isSafeInteger(seconds) && seconds > 0 && seconds < MAX_EPOCH_SECONDS
    ? seconds
    : 0;
}

export function formatJobLog(log) {
  return String(log ?? "").split("\n").map(line => {
    const match = line.match(/^@z2k-ts:([0-9]+)\|(.*)$/);
    if (!match) return line;
    const seconds = epochSeconds(match[1]);
    if (!seconds) return line;
    const time = new Date(seconds * 1000).toLocaleTimeString(undefined, {
      hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
    });
    return `[${time}] ${match[2]}`;
  }).join("\n");
}

export function humanAgo(eventEpoch, serverNowEpoch) {
  const event = epochSeconds(eventEpoch);
  const now = epochSeconds(serverNowEpoch);
  if (!event || !now) return "время не синхронизировано";
  const delta = now - event;
  if (delta < -FUTURE_TOLERANCE_SECONDS) return "время не синхронизировано";
  const age = Math.max(0, delta);
  if (age < 60) return age + " с назад";
  if (age < 3600) return Math.floor(age / 60) + " мин назад";
  if (age < 86400) return Math.floor(age / 3600) + " ч назад";
  return Math.floor(age / 86400) + " дн назад";
}
