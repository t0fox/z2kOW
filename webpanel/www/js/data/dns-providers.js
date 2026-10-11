const catalog = [
  {
    id: "cloudflare", name: "Cloudflare", category: "universal", protocols: ["doh", "dot"],
    endpoints: { doh: "https://cloudflare-dns.com/dns-query", dot: "tls://one.one.one.one" },
    ports: { doh: 443, dot: 853 }, verified: true,
    notes: "Стандартный публичный резолвер.",
    source: ["https://developers.cloudflare.com/1.1.1.1/encryption/", "https://developers.cloudflare.com/1.1.1.1/infrastructure/network-operators/"]
  },
  {
    id: "google", name: "Google Public DNS", category: "universal", protocols: ["doh", "dot"],
    endpoints: { doh: "https://dns.google/dns-query", dot: "tls://dns.google" },
    ports: { doh: 443, dot: 853 }, verified: true,
    notes: "DoH RFC 8484 и DoT.",
    source: ["https://developers.google.com/speed/public-dns/docs/secure-transports", "https://developers.google.com/speed/public-dns/docs/using"]
  },
  {
    id: "quad9", name: "Quad9 (secure)", category: "filtering", protocols: ["doh", "doh3", "dot", "doq", "dnscrypt"],
    endpoints: {
      doh: "https://dns.quad9.net/dns-query", doh3: "h3://dns.quad9.net/dns-query",
      dot: "tls://dns.quad9.net", doq: "quic://dns.quad9.net:853",
      dnscrypt: "sdns://AQMAAAAAAAAADDkuOS45Ljk6ODQ0MyBnyEe4yHWM0SAkVUO-dWdG3zTfHYTAC4xHA2jfgh2GPhkyLmRuc2NyeXB0LWNlcnQucXVhZDkubmV0"
    },
    ports: { doh: 443, doh3: 443, dot: 853, doq: 853, dnscrypt: 8443 }, verified: true,
    notes: "Профиль с блокировкой вредоносных доменов и DNSSEC; DNSCrypt stamp взят из текущей конфигурации z2kOW.",
    source: ["https://www.quad9.net/service/service-addresses-and-features/", "https://quad9.net/news/blog/quad9-enables-dns-over-http-3-and-dns-over-quic/", "https://www.quad9.net/quad9-resolvers.toml", "https://github.com/t0fox/z2kOW/blob/main/platform/openwrt/dnsproxy.sh"]
  },
  {
    id: "adguard", name: "AdGuard DNS (Default)", category: "filtering", protocols: ["doh", "dot", "doq"],
    endpoints: { doh: "https://dns.adguard-dns.com/dns-query", dot: "tls://dns.adguard-dns.com", doq: "quic://dns.adguard-dns.com" },
    ports: { doh: 443, dot: 853, doq: 853 }, verified: true,
    notes: "Стандартный профиль блокирует рекламу, трекеры и фишинг. DNSCrypt provider name опубликован, но dnsproxy-ready stamp не подтверждён и не включён для выбора.",
    source: ["https://adguard-dns.io/kb/general/dns-providers/"]
  },
  {
    id: "comss", name: "Comss", category: "universal", protocols: ["doh", "dot", "doq"],
    endpoints: { doh: "https://dns.comss.one/dns-query", dot: "tls://dns.comss.one", doq: "quic://dns.comss.one" }, ports: { doh: 443, dot: 853, doq: 853 }, verified: true,
    notes: "Официальная документация описывает защищённые протоколы; upstream разрешается через общий список bootstrap.",
    source: ["https://www.comss.ru/page.php?id=7315", "https://www.comss.ru/page.php?id=12919"]
  },
  {
    id: "xbox", name: "Xbox DNS", category: "regional", protocols: ["doh", "dot"],
    endpoints: { doh: "https://xbox-dns.ru/dns-query", dot: "tls://xbox-dns.ru" },
    ports: { doh: 443, dot: 853 }, verified: true,
    notes: "Ограниченный и нестабильный сервис: сообщение от 10 октября говорит, что DNS и Xbox Live остаются доступны, пока это разрешено; маршруты других сервисов могут отключаться.",
    source: ["https://t.me/s/xbox_dns", "https://supercell.xbox-dns.ru/", "https://github.com/t0fox/z2kOW/blob/main/platform/openwrt/dnsproxy.sh"]
  },
  ...[ ["ru", "geohide.ru"], ["eu", "eu.geohide.ru"], ["us", "us.geohide.ru"] ].map(([region, host]) => ({
    id: `geohide_${region}`, name: `GeoHide ${region.toUpperCase()}`, category: "regional", region,
    protocols: ["doh", "doh3", "dot", "doq", "dns"],
    endpoints: { doh: `https://${host}/dns-query`, doh3: `h3://${host}/dns-query`, dot: `tls://${host}`, doq: `quic://${host}`, dns: host }, ports: { doh: 443, doh3: 443, dot: 853, doq: 853, dns: 53 }, verified: false,
    notes: "RU/EU/US endpoints совпадают с текущими пресетами z2kOW; официальная страница не подтверждает точные региональные hosts, поэтому endpoint-ы не подтверждены.",
    source: ["https://geohide.ru/", "https://github.com/t0fox/z2kOW/blob/main/platform/openwrt/dnsproxy.sh"]
  })),
  {
    id: "dns_ai", name: "DNS-AI", category: "universal", protocols: ["doh", "doh3", "dot", "doq"],
    endpoints: { doh: "https://dns.dns-ai.ru/dns-query", doh3: "h3://dns.dns-ai.ru/dns-query", dot: "tls://dns.dns-ai.ru", doq: "quic://dns.dns-ai.ru:853" }, ports: { doh: 443, doh3: 443, dot: 853, doq: 853 }, verified: true,
    notes: "Официальная страница публикует защищённые endpoints; upstream разрешается через общий список bootstrap.", source: ["https://dns-ai.ru/"]
  },
  ...[
    ["xyz", "XyZ DNS", "https://dns.yo1nk.app/dns-query"],
    ["malw", "dns.malw.link", "https://dns.malw.link/dns-query"],
    ["astracat", "dns.astracat.ru", "https://dns.astracat.ru/dns-query"],
    ["mafioznik", "dns.mafioznik.xyz", "https://dns.mafioznik.xyz/dns-query"],
    ["malw_cloudflare", "malw Cloudflare Gateway", "https://5u35p8m9i7.cloudflare-gateway.com/dns-query"],
    ["nullsproxy", "nullsproxy", "https://dns.nullsproxy.com/dns-query"]
  ].map(([id, name, doh]) => ({
    id, name, category: "universal", protocols: ["doh"], endpoints: { doh }, ports: { doh: 443 }, verified: false,
    notes: "Настройка сохранена из текущего DoH пресета z2kOW; официальные настройки провайдера не подтверждены.",
    source: ["https://github.com/t0fox/z2kOW/blob/main/platform/openwrt/dnsproxy.sh"]
  })),
  {
    id: "default", name: "Cloudflare + Google", category: "universal", protocols: ["doh"],
    endpoints: { doh: ["https://cloudflare-dns.com/dns-query", "https://dns.google/dns-query"] },
    ports: { doh: 443 }, verified: true,
    notes: "Комбинированный пресет z2kOW использует оба документированных DoH endpoint.",
    source: ["https://developers.cloudflare.com/1.1.1.1/encryption/", "https://developers.google.com/speed/public-dns/docs/secure-transports", "https://github.com/t0fox/z2kOW/blob/main/platform/openwrt/dnsproxy.sh"]
  }
];

catalog.splice(1, 0,
  {
    id: "cloudflare_security", name: "Cloudflare Security", category: "filtering", profile: "malware",
    protocols: ["doh", "dot"], endpoints: { doh: "https://security.cloudflare-dns.com/dns-query", dot: "tls://security.cloudflare-dns.com" },
    ports: { doh: 443, dot: 853 }, verified: true, notes: "Блокировка вредоносных доменов.",
    source: ["https://developers.cloudflare.com/1.1.1.1/setup/"]
  },
  {
    id: "cloudflare_family", name: "Cloudflare Family", category: "filtering", profile: "malware-and-adult-content",
    protocols: ["doh", "dot"], endpoints: { doh: "https://family.cloudflare-dns.com/dns-query", dot: "tls://family.cloudflare-dns.com" },
    ports: { doh: 443, dot: 853 }, verified: true, notes: "Блокировка вредоносных доменов и контента для взрослых.",
    source: ["https://developers.cloudflare.com/1.1.1.1/setup/"]
  },
  {
    id: "adguard_family", name: "AdGuard DNS Family", category: "filtering", profile: "family",
    protocols: ["doh", "dot", "doq"],
    endpoints: { doh: "https://family.adguard-dns.com/dns-query", dot: "tls://family.adguard-dns.com", doq: "quic://family.adguard-dns.com" },
    ports: { doh: 443, dot: 853, doq: 853 }, verified: true,
    notes: "Функции Default плюс блокировка сайтов для взрослых и Safe Search.", source: ["https://adguard-dns.io/kb/general/dns-providers/"]
  },
  {
    id: "adguard_unfiltered", name: "AdGuard DNS Non-filtering", category: "universal", profile: "non-filtering",
    protocols: ["doh", "dot", "doq"],
    endpoints: { doh: "https://unfiltered.adguard-dns.com/dns-query", dot: "tls://unfiltered.adguard-dns.com", doq: "quic://unfiltered.adguard-dns.com" },
    ports: { doh: 443, dot: 853, doq: 853 }, verified: true,
    notes: "Защищённое соединение без DNS-фильтрации.", source: ["https://adguard-dns.io/kb/general/dns-providers/"]
  },
  {
    id: "nextdns", name: "NextDNS (profile required)", category: "personal", protocols: ["doh", "dot"],
    endpoints: { doh: "https://dns.nextdns.io/{profile_id}", dot: "tls://{profile_id}.dns.nextdns.io" }, ports: { doh: 443, dot: 853 }, verified: true,
    notes: "Шаблон требует ID конфигурации NextDNS; готового публичного endpoint без профиля нет.",
    source: ["https://help.nextdns.io/t/g9hmvan/what-is-linked-ip", "https://help.nextdns.io/t/m1yttwc/ddns-hostname"]
  }
);

const lastVerified = "2026-10-11";
function freezeProfile(data) {
  return Object.freeze({ ...data, source: Object.freeze(data.source), protocols: Object.freeze(data.protocols), endpoints: Object.freeze(data.endpoints), ports: Object.freeze(data.ports), lastVerified });
}
const moreProfiles = [
  ...[
    ["p0", "Unfiltered", "universal"], ["p1", "Malware", "filtering"],
    ["p2", "Ads & Tracking", "filtering"], ["p3", "Social", "filtering"],
    ["family", "Family", "filtering"]
  ].map(([slug, label, category]) => ({
    id: `controld_${slug}`, name: `Control D ${label}`, category, profile: slug,
    protocols: ["doh", "dot", "doq"], endpoints: { doh: `https://freedns.controld.com/${slug}`, dot: `tls://${slug}.freedns.controld.com`, doq: `quic://${slug}.freedns.controld.com` },
    ports: { doh: 443, dot: 853, doq: 853 }, verified: true, notes: "Официальный бесплатный профиль Control D.",
    source: ["https://docs.controld.com/docs/free-dns", "https://docs.controld.com/docs/control-d-ip-ranges"]
  })),
  ...[
    ["light", "Light"], ["normal", "Normal"], ["pro", "Pro"],
    ["proplus", "Pro Plus"], ["ultimate", "Ultimate"]
  ].map(([slug, label]) => {
    const tag = `x-hagezi-${slug}`;
    return {
      id: `controld_hagezi_${slug}`, name: `HaGeZi ${label} via Control D`, category: "filtering", profile: tag,
      protocols: ["doh", "dot", "doq"], endpoints: { doh: `https://freedns.controld.com/${tag}`, dot: `tls://${tag}.freedns.controld.com`, doq: `quic://${tag}.freedns.controld.com` },
      ports: { doh: 443, dot: 853, doq: 853 }, verified: true, notes: "Профиль HaGeZi опубликован как отдельный бесплатный resolver endpoint Control D.",
      source: ["https://docs.controld.com/docs/free-dns", "https://docs.controld.com/docs/control-d-ip-ranges"]
    };
  }),
  ...[
    ["family", "Family", "https://doh.cleanbrowsing.org/doh/family-filter/", "family-filter-dns.cleanbrowsing.org"],
    ["adult", "Adult", "https://doh.cleanbrowsing.org/doh/adult-filter/", "adult-filter-dns.cleanbrowsing.org"],
    ["security", "Security", "https://doh.cleanbrowsing.org/doh/security-filter/", "security-filter-dns.cleanbrowsing.org"]
  ].map(([slug, label, doh, dot]) => ({
    id: `cleanbrowsing_${slug}`, name: `CleanBrowsing ${label}`, category: "filtering", protocols: ["doh", "dot"],
    endpoints: { doh, dot: `tls://${dot}` }, ports: { doh: 443, dot: 853 }, verified: true,
    notes: `Профиль ${label} CleanBrowsing.`, source: ["https://cleanbrowsing.org/support/troubleshooting/firewall-dns-requirements"]
  })),
  ...[
    ["basic", "Basic", "common.dot.dns.yandex.net", "universal"],
    ["safe", "Safe", "safe.dot.dns.yandex.net", "filtering"],
    ["family", "Family", "family.dot.dns.yandex.net", "filtering"]
  ].map(([slug, label, host, category]) => ({
    id: `yandex_${slug}`, name: `Yandex DNS ${label}`, category, protocols: ["dot"], endpoints: { dot: `tls://${host}` },
    ports: { dot: 853 }, verified: true,
    notes: `DoT host ${host} опубликован официально. Путь DoH не подтверждён.`, source: ["https://dns.yandex.ru/"]
  })),
  {
    id: "dns_sb", name: "DNS.SB", category: "universal", protocols: ["doh"], endpoints: { doh: "https://doh.dns.sb/dns-query" },
    ports: { doh: 443 }, verified: true,
    notes: "Официально опубликованный DoH endpoint.", source: ["https://dns.sb/doh/"]
  },
  {
    id: "libredns", name: "LibreDNS", category: "universal", protocols: ["doh", "dot"],
    endpoints: { doh: "https://doh.libredns.gr/dns-query", dot: "tls://dot.libredns.gr" }, ports: { doh: 443, dot: 853 }, verified: true,
    notes: "Публичный зашифрованный DNS.", source: ["https://libredns.gr/"]
  },
  {
    id: "libredns_noads", name: "LibreDNS No Ads", category: "filtering", profile: "noads", protocols: ["doh", "dot"],
    endpoints: { doh: "https://doh.libredns.gr/noads", dot: "tls://noads.libredns.gr" }, ports: { doh: 443, dot: 853 }, verified: true,
    notes: "Фильтрует рекламу и трекеры.", source: ["https://libredns.gr/"]
  }
];

export const DNS_PROVIDER_CATALOG = Object.freeze([...catalog, ...moreProfiles].map(freezeProfile));
