import "./style.css";
import { createScene, type Scene } from "./scene.ts";

// ---------- Mission model (all values are fictional and illustrative) ----------
type PhaseId = "cruise" | "entry" | "descent" | "touchdown";
interface Phase {
  id: PhaseId;
  label: string;
  start: number; // progress where the phase begins
  key: number; // progress the phase button jumps to
  caption: string;
}

const PHASES: readonly Phase[] = [
  { id: "cruise", label: "Cruise", start: 0, key: 0, caption: "Cruise. Seven months of quiet, and Mars is finally more than a point of light." },
  { id: "entry", label: "Entry", start: 0.38, key: 0.5, caption: "Entry. The heat shield meets thin air and the view turns to fire." },
  { id: "descent", label: "Descent", start: 0.72, key: 0.84, caption: "Descent. Shield away, horizon rising, engines throttling against the fall." },
  { id: "touchdown", label: "Touchdown", start: 0.93, key: 1, caption: "Touchdown. Dust settles over the Halden Plain. VESPER-1 is down." },
];

const DURATION = 28; // seconds for the full approach
const MARS_RADIUS_KM = 3390;
const H_START = 2.6;
const H_END = 0.00035;
const VELOCITY: readonly (readonly [number, number])[] = [
  [0, 5900], [0.38, 5400], [0.6, 1600], [0.72, 420], [0.93, 18], [1, 0],
]; // m/s

const phaseAt = (p: number): Phase => {
  let current = PHASES[0];
  for (const phase of PHASES) if (p >= phase.start) current = phase;
  return current;
};

const altitudeKm = (p: number): number => {
  const ease = p * p * (3 - 2 * p);
  const h = Math.exp(Math.log(H_START) + (Math.log(H_END) - Math.log(H_START)) * ease);
  return (h - H_END) * MARS_RADIUS_KM;
};

const velocityMs = (p: number): number => {
  for (let i = 1; i < VELOCITY.length; i++) {
    const [p1, v1] = VELOCITY[i];
    if (p <= p1) {
      const [p0, v0] = VELOCITY[i - 1];
      return v0 + ((v1 - v0) * (p - p0)) / (p1 - p0);
    }
  }
  return 0;
};

const fmt = new Intl.NumberFormat("en-US");
const formatAltitude = (km: number): string =>
  km >= 10 ? `${fmt.format(Math.round(km))} km` : km >= 1 ? `${km.toFixed(1)} km` : `${fmt.format(Math.round(km * 1000))} m`;
const formatVelocity = (ms: number): string =>
  ms >= 1000 ? `${(ms / 1000).toFixed(2)} km/s` : `${fmt.format(Math.round(ms))} m/s`;
const formatClock = (p: number): string => {
  const s = Math.round((1 - p) * 420);
  const mm = String(Math.floor(s / 60)).padStart(2, "0");
  const ss = String(s % 60).padStart(2, "0");
  return s === 0 ? "T+00:00" : `T−${mm}:${ss}`;
};

// ---------- DOM ----------
const $ = <T extends HTMLElement>(id: string): T => document.getElementById(id) as T;
const hero = $("hero");
const canvas = $<HTMLCanvasElement>("scene");
const cta = $<HTMLButtonElement>("cta");
const scrub = $<HTMLInputElement>("scrub");
const caption = $("caption");
const live = $("live");
const tAlt = $("t-alt");
const tVel = $("t-vel");
const tPhase = $("t-phase");
const tClock = $("t-clock");
const phaseButtons = [...document.querySelectorAll<HTMLButtonElement>(".phases button")];

const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

// ---------- State ----------
let target = 0; // where the visitor wants to be
let shown = 0; // what is on screen (eases toward target)
let playing = false;
let dragging = false;
let lastPhase: PhaseId | null = null;
let lastState = "";
let lastText = "";

const setTarget = (p: number) => {
  target = Math.min(1, Math.max(0, p));
};

const play = () => {
  if (target >= 0.999) {
    target = 0;
    shown = 0;
  }
  playing = true;
};
const pause = () => {
  playing = false;
};

const stepToNextPhase = () => {
  // Reduced motion: move one phase at a time instead of flying continuously.
  const next = PHASES.find((phase) => phase.key > target + 0.001);
  setTarget(next ? next.key : 0);
  shown = target;
};

cta.addEventListener("click", () => {
  if (reducedMotion.matches) return stepToNextPhase();
  if (playing) pause();
  else play();
});

scrub.addEventListener("pointerdown", () => (dragging = true));
window.addEventListener("pointerup", () => (dragging = false));
scrub.addEventListener("input", () => {
  pause();
  setTarget(Number(scrub.value) / 1000);
  if (reducedMotion.matches) shown = target;
});

for (const button of phaseButtons) {
  button.addEventListener("click", () => {
    const phase = PHASES.find((item) => item.id === button.dataset.phase)!;
    pause();
    setTarget(phase.key);
    if (reducedMotion.matches) shown = target;
  });
}

// In-page nav: move focus to the section instead of scrolling a one-screen page.
for (const link of document.querySelectorAll<HTMLAnchorElement>('.nav nav a[href^="#"]')) {
  link.addEventListener("click", (event) => {
    event.preventDefault();
    const id = link.getAttribute("href")!.slice(1);
    (id === "timeline" ? scrub : $(id)).focus();
  });
}

// ---------- Per-frame update ----------
const update = (dt: number) => {
  if (playing) {
    target = Math.min(1, target + dt / DURATION);
    shown = target;
    if (target >= 1) playing = false;
  } else if (shown !== target) {
    const k = 1 - Math.exp(-dt * 5);
    shown += (target - shown) * k;
    if (Math.abs(target - shown) < 0.0004) shown = target;
  }
  render();
  return shown;
};

const render = () => {
  const phase = phaseAt(shown);
  const state = playing ? "playing" : target >= 0.999 ? "complete" : target > 0 ? "paused" : "idle";

  const text = `${formatAltitude(altitudeKm(shown))}|${formatVelocity(velocityMs(shown))}|${formatClock(shown)}`;
  if (text !== lastText) {
    lastText = text;
    const [alt, vel, clock] = text.split("|");
    tAlt.textContent = alt;
    tVel.textContent = vel;
    tClock.textContent = clock;
    hero.style.setProperty("--p", shown.toFixed(4));
    if (!dragging) scrub.value = String(Math.round(shown * 1000));
    scrub.setAttribute("aria-valuetext", `${phase.label}, ${Math.round(shown * 100)} percent`);
  }

  if (phase.id !== lastPhase) {
    lastPhase = phase.id;
    hero.dataset.phase = phase.id;
    tPhase.textContent = phase.label;
    caption.textContent = phase.caption;
    live.textContent = phase.caption;
    for (const button of phaseButtons) button.setAttribute("aria-pressed", String(button.dataset.phase === phase.id));
  }

  const key = `${state}|${reducedMotion.matches}`;
  if (key !== lastState) {
    lastState = key;
    hero.dataset.state = state;
    cta.textContent = reducedMotion.matches
      ? state === "complete" ? "Back to cruise" : state === "idle" ? "Begin approach" : "Next phase"
      : state === "playing" ? "Pause approach"
      : state === "complete" ? "Replay approach"
      : state === "paused" ? "Resume approach"
      : "Begin approach";
  }
};

// ---------- Scene: WebGPU via vgpu, or a static CSS poster ----------
const startFallbackLoop = () => {
  hero.dataset.gpu = "off";
  $("static-note").hidden = false;
  let previous = performance.now();
  const tick = (now: number) => {
    update(Math.min(0.1, (now - previous) / 1000));
    previous = now;
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
};

const start = async () => {
  render();
  const forceFallback = new URLSearchParams(location.search).has("nogpu");
  if (forceFallback || !("gpu" in navigator)) return startFallbackLoop();
  let scene: Scene;
  try {
    scene = await createScene(canvas, {
      frame: (dt) => ({ progress: update(dt), motion: reducedMotion.matches ? 0 : 1 }),
    });
  } catch (error) {
    console.warn("WebGPU scene unavailable, showing static view.", error);
    return startFallbackLoop();
  }
  hero.dataset.gpu = "on";
  window.addEventListener("pagehide", () => scene.dispose(), { once: true });
};

void start();
