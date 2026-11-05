// The synthetic world: one security leader's real-world-like communications
// surface. This is ground truth — workstreams, people, sanctioned workspaces,
// and the through-lines the corpus generator weaves across surfaces. Inference
// is later scored against this (did clustering find these through-lines?).
// No real person or mailbox; every address is a reserved .example domain.

export const PROTAGONIST = { name: 'Alex Cursi', email: 'alex@stoneridge.example', handle: 'U-ALEX' };

// Multi-affiliate org: same first.last exists at two domains, sometimes the
// same person, sometimes not — exercises full-address identity keys.
export const PEOPLE = [
  { id: 'U-NOAH', name: 'Noah Park', email: 'noah.park@stoneridge.example', role: 'internal', slack: 'U-NOAH' },
  { id: 'U-SAMW', name: 'Sam Whitfield', email: 'sam.whitfield@stoneridge.example', role: 'internal', slack: 'U-SAMW' },
  { id: 'U-ERIN', name: 'Erin Vance', email: 'erin.vance@stoneridge.example', role: 'internal', slack: 'U-ERIN' },
  { id: 'U-MCHEN', name: 'M. Chen', email: 'm.chen@stoneridge.example', role: 'principal', slack: 'U-MCHEN' },
  { id: 'U-COUNSEL', name: 'Dana Osei', email: 'counsel@stoneridge.example', role: 'internal', slack: 'U-COUNSEL' },
  { id: 'U-PRIYA', name: 'Priya Raghavan', email: 'priya.raghavan@stoneridge.example', role: 'internal', slack: 'U-PRIYA' },
  { id: 'U-TOM', name: 'Tom Lindqvist', email: 'tom.lindqvist@stoneridge.example', role: 'internal', slack: 'U-TOM' },
  { id: 'EXT-JORDAN', name: 'Jordan Lee', email: 'jordan.lee@securetooling.example', role: 'external' },
  { id: 'EXT-RILEY', name: 'Riley Fox', email: 'riley.fox@identitycloud.example', role: 'external' },
  // affiliate collision: same local part, different domain, DIFFERENT person
  { id: 'AFF-KAI-A', name: 'Kai Rivera', email: 'kai.rivera@stoneridge.example', role: 'internal', slack: 'U-KAI' },
  { id: 'AFF-KAI-B', name: 'Kai Rivera', email: 'kai.rivera@stoneridge-labs.example', role: 'affiliate' },
];

export const PRINCIPALS = ['m.chen@stoneridge.example'];

// Seven workstreams — the through-lines. Each names the surfaces it lives on,
// its recurring people, an optional formal anchor, and behavioural flavour the
// generator uses to shape traffic.
export const WORKSTREAMS = [
  { slug: 'iam-unification', name: 'IAM Unification', anchor: 'IAM-204',
    channels: ['C-IAM'], people: ['U-NOAH', 'U-SAMW', 'EXT-RILEY', 'U-MCHEN'],
    flavour: 'planning', profile: 'work', weight: 3 },
  { slug: 'phish-incident', name: 'Phish Incident Response', anchor: 'SEC-1181',
    channels: ['C-SECINC'], people: ['U-NOAH', 'U-SAMW', 'U-ERIN'],
    flavour: 'incident', profile: 'work', weight: 2, bursty: true },
  { slug: 'securetooling-renewal', name: 'SecureTooling Renewal', anchor: null,
    channels: ['D-LEGAL'], people: ['EXT-JORDAN', 'U-COUNSEL'],
    flavour: 'negotiation', profile: 'work', weight: 2, externalUrgency: true },
  { slug: 'secure-sdlc', name: 'Secure SDLC Uplift', anchor: 'SDLC-77',
    channels: ['C-APPSEC'], people: ['U-SAMW', 'U-PRIYA', 'AFF-KAI-A'],
    flavour: 'process', profile: 'work', weight: 3, mostlyUnthreaded: true },
  { slug: 'board-deck-q3', name: 'Board Deck Q3', anchor: null,
    channels: ['C-EXEC'], people: ['U-MCHEN', 'U-TOM'],
    flavour: 'reporting', profile: 'work', weight: 1 },
  { slug: 'vendor-tenant-migration', name: 'Tenant Migration', anchor: 'IAM-231',
    channels: ['C-IAM'], people: ['EXT-RILEY', 'U-NOAH', 'AFF-KAI-B'],
    flavour: 'planning', profile: 'work', weight: 2 },
  { slug: 'ajilty-homelab', name: 'Ajilty Homelab', anchor: null,
    channels: ['C-AJILTY'], people: [], flavour: 'solo', profile: 'personal', weight: 1 },
];

// Automation sources — noise the FILTER path should catch, never workstreams.
export const AUTOMATION = [
  { from: 'ci-noreply@stoneridge.example', subject: 'Nightly Semgrep digest', bulk: true, unsub: 'leave-ci@stoneridge.example' },
  { from: 'builds@stoneridge.example', subject: 'Pipeline summary', bulk: true, unsub: 'leave-builds@stoneridge.example' },
  { from: 'updates@newsletter.example', subject: 'Your weekly digest', bulk: true, unsub: null, poisoned: true },
  { from: 'alerts@status.example', subject: 'Uptime report', bulk: true, unsub: 'unsub@status.example' },
];

// Sentence fragments per flavour — enough lexical variety that thread inference
// and topic clustering have real signal to work with, not lorem ipsum.
export const LEXICON = {
  planning: ['tenant migration', 'SCIM provisioning', 'Okta cutover', 'directory sync', 'group mapping',
    'pilot ring', 'rollback plan', 'cutover window', 'break-glass account', 'lifecycle hooks'],
  incident: ['gateway logs', 'blast radius', 'credential reset', 'mailbox purge', 'containment',
    'IOC sweep', 'all-staff notice', 'clicked the link', 'token revocation', 'forensics'],
  negotiation: ['MSA redlines', 'liability cap', 'data residency clause', 'renewal uplift', 'EOQ pricing',
    'seat count', 'auto-renew', 'termination for convenience', 'SOC 2 report', 'DPA'],
  process: ['SAST gating', 'threat model', 'secure defaults', 'paved road', 'pre-merge checks',
    'dependency pinning', 'secrets scanning', 'exception process', 'coverage gap', 'baseline policy'],
  reporting: ['risk register', 'quarterly metrics', 'headcount ask', 'roadmap slip', 'exec summary',
    'KRIs', 'audit findings', 'remediation SLA', 'budget line', 'narrative'],
  solo: ['agent orchestration', 'MCP gateway', 'homelab rebuild', 'k3s cluster', 'backup job',
    'reverse proxy', 'GPU node', 'observability stack', 'cost cap', 'nightly sync'],
};
