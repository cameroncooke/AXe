import React from 'react';
import {AbsoluteFill, Easing, Img, staticFile} from 'remotion';
import {C, Fade, FONT, GRAD, inOut, Line, MONO, outExpo, Rise, Scene, Terminal, tw, useT, VideoAt} from './lib';
import {Duo} from './hardware';

// The AXe 2.1 film. One take, recorded twice at once: the iPhone Duo's own screen recording
// (public/v21/duo.mp4) and the simulator on the Mac (public/v21/mac.mp4). Times below are seconds
// in the Duo recording unless they say otherwise.
const DUO_SRC = 'v21/duo.mp4';
const MAC_SRC = 'v21/mac.mp4';
const SRC_RATE = 3; // see VideoAt: keeps the frozen frame number inside the composition
/**
 * mac.mp4 shows at `duo time + MAC_LAG` what the Duo shows at `duo time`. Measured by matching the two
 * pictures; it holds from Duo time 66 onwards (9.89 to 9.94 s at every point checked).
 */
const MAC_LAG = -9.91;

// ───────────────────────────── The cut ─────────────────────────────
type Seg = {a: number; b: number; rate: number; dissolve?: boolean};
type Phase = {name: string; segs: Seg[]};
const PHASES: Phase[] = [
  // Home screen, the agent's app, the mirror beside it, the simulator arrives. 1.35 to 3.75 is a list of other sessions.
  {name: 'open', segs: [{a: 0, b: 1.35, rate: 1}, {a: 3.75, b: 9.15, rate: 1.5, dissolve: true}, {a: 9.15, b: 13.0, rate: 1.25}]},
  // The first prompt is typed and the agent opens Lisbon.
  {name: 'ask', segs: [{a: 13.0, b: 23.6, rate: 3.2}, {a: 23.6, b: 35.6, rate: 2}]},
  // The web sign-in page. 36.6 to 55.8 is the model thinking, with nothing moving.
  {name: 'web', segs: [{a: 35.6, b: 36.6, rate: 1}, {a: 55.8, b: 76.5, rate: 2, dissolve: true}]},
  {name: 'booked', segs: [{a: 76.5, b: 92.5, rate: 3}]},
  // The person's own turn in the mirror.
  {name: 'you', segs: [{a: 93.0, b: 112.6, rate: 1.8}]},
  // The second prompt, the change, and the person trying it.
  {name: 'change', segs: [{a: 112.6, b: 136.3, rate: 6}, {a: 136.3, b: 158.5, rate: 2.6}, {a: 158.5, b: 170.5, rate: 2.4}]},
];
const segDur = (s: Seg) => (s.b - s.a) / s.rate;
const PHASE_AT: Record<string, number> = {};
const PHASE_END: Record<string, number> = {};
let acc = 0;
for (const p of PHASES) {
  PHASE_AT[p.name] = acc;
  for (const s of p.segs) acc += segDur(s);
  PHASE_END[p.name] = acc;
}
const STORY_RAW = acc;
export const STORY = Math.ceil(STORY_RAW * 2) / 2;

/** The source time shown at story time `t`, and the frame to dissolve from just after a cut. */
const srcAt = (t: number): {src: number; from?: number; mix: number} => {
  let at = 0;
  let last = 0;
  for (const p of PHASES) {
    for (const s of p.segs) {
      const d = segDur(s);
      if (t < at + d) {
        const src = s.a + (t - at) * s.rate;
        if (s.dissolve && t - at < 0.35) return {src, from: last, mix: (t - at) / 0.35};
        return {src, mix: 1};
      }
      at += d;
      last = s.b;
    }
  }
  return {src: last, mix: 1};
};
/** The story time at which source time `src` is on screen. */
const storyOf = (src: number) => {
  let at = 0;
  for (const p of PHASES) {
    for (const s of p.segs) {
      if (src >= s.a && src <= s.b) return at + (src - s.a) / s.rate;
      at += segDur(s);
    }
  }
  return at;
};

// ───────────────────────────── Shared pieces ─────────────────────────────
const fill: React.CSSProperties = {width: '100%', height: '100%', objectFit: 'cover', display: 'block'};

const Caption: React.FC<{from: number; to: number; text: string; eyebrow?: string; t: number; sub?: string}> = ({from, to, text, eyebrow, t, sub}) => {
  if (t < from - 0.05 || t > to + 0.4) return null;
  const o = Math.min(tw(t, from, from + 0.45), tw(t, to, to + 0.35, 1, 0, Easing.in(Easing.quad)));
  const y = tw(t, from, from + 0.6, 26, 0);
  return (
    <div style={{position: 'absolute', left: 0, right: 0, bottom: 44, display: 'flex', justifyContent: 'center', opacity: o, transform: `translateY(${y}px)`}}>
      <div
        style={{
          padding: '20px 44px 22px',
          borderRadius: 28,
          background: 'rgba(5,7,12,0.82)',
          border: `1px solid ${C.line}`,
          boxShadow: '0 20px 70px rgba(0,0,0,0.6)',
          textAlign: 'center',
          maxWidth: 1500,
        }}
      >
        {eyebrow && (
          <div style={{fontFamily: MONO, fontSize: 20, letterSpacing: '0.22em', textTransform: 'uppercase', color: C.cyan, marginBottom: 8}}>{eyebrow}</div>
        )}
        <div style={{fontFamily: FONT, fontWeight: 500, fontSize: 46, lineHeight: 1.15, letterSpacing: '-0.02em', color: C.text}}>{text}</div>
        {sub && <div style={{fontFamily: FONT, fontSize: 28, color: C.sub, marginTop: 8}}>{sub}</div>}
      </div>
    </div>
  );
};

/** A laptop drawn in CSS. Its screen shows an agent's terminal and the Simulator with the Mac-side recording. */
const MAC_W = 1180;
const MAC_H = 800;
const Mac: React.FC<{simTime: number; lines: Line[]}> = ({simTime, lines}) => {
  const screenH = 720;
  const phoneH = 600;
  const phoneW = (phoneH * 604) / 1312;
  return (
    <div style={{width: MAC_W, height: MAC_H, position: 'relative'}}>
      <div
        style={{
          position: 'absolute',
          left: 40,
          top: 0,
          width: MAC_W - 80,
          height: screenH,
          borderRadius: 26,
          background: '#0b0d12',
          border: '3px solid #3a4049',
          boxShadow: '0 40px 120px rgba(0,0,0,0.6), 0 0 80px rgba(34,211,238,0.08)',
          overflow: 'hidden',
        }}
      >
        <div style={{position: 'absolute', inset: 14, borderRadius: 14, overflow: 'hidden', background: 'linear-gradient(135deg, #101624 0%, #0a0f1a 60%, #141a2b 100%)'}}>
          <div style={{height: 30, background: 'rgba(255,255,255,0.05)', display: 'flex', alignItems: 'center', padding: '0 16px', gap: 22, fontFamily: FONT, fontSize: 14, color: C.sub}}>
            <span style={{color: C.text, fontWeight: 600}}>Terminal</span>
            <span>Shell</span>
            <span>Edit</span>
            <span>View</span>
            <span>Window</span>
          </div>
          <Terminal lines={lines} width={620} height={560} title="agent · Trips" fontSize={17} style={{position: 'absolute', left: 28, top: 58, borderRadius: 14}} />
          {/* The Simulator window */}
          <div style={{position: 'absolute', left: 700, top: 44, width: phoneW + 44, height: phoneH + 62, borderRadius: 14, background: 'rgba(17,22,32,0.96)', border: `1px solid ${C.line}`, boxShadow: '0 30px 80px rgba(0,0,0,0.55)'}}>
            <div style={{height: 34, display: 'flex', alignItems: 'center', padding: '0 12px', gap: 7}}>
              {['#FF5F57', '#FEBC2E', '#28C840'].map((c) => (
                <div key={c} style={{width: 11, height: 11, borderRadius: 6, background: c, opacity: 0.85}} />
              ))}
              <div style={{flex: 1, textAlign: 'center', fontFamily: FONT, fontSize: 13, color: C.sub, marginRight: 40}}>Trips Demo</div>
            </div>
            <div style={{position: 'absolute', left: 22, top: 40, width: phoneW, height: phoneH, borderRadius: 34, overflow: 'hidden', background: '#000', border: '3px solid #1a1d23'}}>
              <VideoAt src={MAC_SRC} time={Math.max(0, simTime)} rate={SRC_RATE} style={fill} />
            </div>
          </div>
        </div>
      </div>
      {/* Base */}
      <div style={{position: 'absolute', left: 0, top: screenH - 2, width: MAC_W, height: 26, borderRadius: '6px 6px 22px 22px', background: 'linear-gradient(180deg, #6a717d 0%, #2b3038 45%, #14171c 100%)'}} />
      <div style={{position: 'absolute', left: MAC_W / 2 - 90, top: screenH - 2, width: 180, height: 10, borderRadius: '0 0 12px 12px', background: '#14171c'}} />
    </div>
  );
};

// What the agent ran in this take, as the terminal on the Mac shows it.
const HOME_LINES: Line[] = [
  {at: 0.3, kind: 'dim', text: '› Book the Lisbon trip'},
  {at: 0.5, kind: 'gap'},
  {at: 0.8, kind: 'cmd', text: 'axe describe-ui --agent', typeDur: 0.4},
  {at: 1.4, kind: 'out', text: 'e22|tap|button|Lisbon, Portugal · 12 to 16 March|'},
  {at: 1.5, kind: 'out', text: 'e26|tap|button|Kyoto, Japan · 3 to 10 April|'},
  {at: 1.6, kind: 'out', text: 'e30|tap|button|Reykjavik, Iceland · 20 to 23 …|'},
  {at: 1.9, kind: 'gap'},
  {at: 2.1, kind: 'cmd', text: 'axe tap --agent --ref e22', typeDur: 0.4},
  {at: 2.8, kind: 'ok', text: 'tapped · Lisbon'},
  {at: 3.1, kind: 'gap'},
  {at: 3.3, kind: 'cmd', text: 'axe tap --agent --ref e41', typeDur: 0.4},
  {at: 4.0, kind: 'ok', text: 'tapped · Book'},
  {at: 4.3, kind: 'gap'},
  {at: 4.5, kind: 'cmd', text: 'axe describe-ui --agent --web', typeDur: 0.5},
  {at: 5.2, kind: 'out', text: 'w3|typeText|text-field|Email|'},
  {at: 5.3, kind: 'out', text: 'w4|typeText|text-field|Password|'},
  {at: 5.4, kind: 'out', text: 'w5|tap|button|Sign in|'},
];
// The simulator on the Mac while the agent opens Lisbon and reaches the sign-in page, in mac.mp4's own
// seconds. That recording skips time while the screen is still, so early on it does not run level with
// the Duo's: the trips list is on screen until 51.4, and the tap on Lisbon follows.
const homeSim = (t: number) => (t < 2.9 ? 51.4 : t < 5.5 ? 51.4 + (t - 2.9) * 0.45 : Math.min(58.5, 52.57 + (t - 5.5) * 1.3));

// ───────────────────────────── 1. At home ─────────────────────────────
export const HOME = 5.5;
export const Home: React.FC = () => {
  const t = useT();
  const o = tw(t, 0, 0.6, 0, 1, Easing.out(Easing.quad));
  return (
    <AbsoluteFill style={{opacity: o}}>
      <div style={{position: 'absolute', left: 960 - MAC_W / 2, top: 70, transform: `translateY(${tw(t, 0, 1.1, 40, 0)}px)`}}>
        <Mac simTime={homeSim(t)} lines={HOME_LINES} />
      </div>
      <Caption t={t} from={0.5} to={HOME - 0.2} text="Your Mac. Your agent. Your app, in the Simulator." />
    </AbsoluteFill>
  );
};

// ───────────────────────────── 2 to 7. Out, with the Duo ─────────────────────────────
const GO = 4.5; // the Mac shrinks away and the folded Duo travels
const UNFOLD = 3.0; // it turns and opens
const T0 = GO + UNFOLD; // story time zero, in scene seconds
export const OUT = T0 + STORY + 0.5;

const SCREEN_H = 740;
const INNER_W = (SCREEN_H * 951) / 669;
const BEZ = SCREEN_H * 0.028; // bezel + band, as in <Duo>
const BODY_W = INNER_W / 2 + BEZ;
const BODY_H = SCREEN_H + 2 * BEZ;
// Where the mirrored simulator's picture sits in the Duo recording, as fractions of the frame.
const SIM = {x: 0.5662, y: 0, w: 0.3067, h: 0.95};
const simX = (f: number) => (SIM.x + SIM.w * f) * INNER_W;
const simY = (f: number) => (SIM.y + SIM.h * f) * SCREEN_H;

const LockScreen: React.FC = () => (
  <div style={{width: '100%', height: '100%', background: 'linear-gradient(160deg, #1b2a4a 0%, #0c1220 55%, #2a1740 100%)', display: 'flex', flexDirection: 'column', alignItems: 'center'}}>
    <div style={{fontFamily: FONT, fontSize: 30, color: 'rgba(255,255,255,0.85)', marginTop: '22%'}}>Thursday 19 November</div>
    <div style={{fontFamily: FONT, fontWeight: 600, fontSize: 150, lineHeight: 1, color: '#fff', letterSpacing: '-0.04em', marginTop: 6}}>9:41</div>
  </div>
);

/** What the Duo's inner screen shows: the recording, a blur over the Home screen's personal widgets, and the dissolve at a cut. */
const DuoScreen: React.FC<{st: number}> = ({st}) => {
  const {src, from, mix} = srcAt(Math.max(0, st));
  const blur = tw(src, 0.75, 1.2, 1, 0, (x) => x);
  return (
    <>
      <VideoAt src={DUO_SRC} time={src} rate={SRC_RATE} style={{...fill, position: 'absolute', inset: 0}} />
      {src < 1.25 && (
        <div style={{position: 'absolute', left: '4.5%', top: '8%', width: '40.5%', height: '57%', overflow: 'hidden', borderRadius: 40, opacity: blur}}>
          <div style={{position: 'absolute', left: -0.045 * INNER_W, top: -0.08 * SCREEN_H, width: INNER_W, height: SCREEN_H, filter: 'blur(16px)'}}>
            <VideoAt src={DUO_SRC} time={src} rate={SRC_RATE} style={fill} />
          </div>
        </div>
      )}
      {from !== undefined && mix < 1 && (
        <div style={{position: 'absolute', inset: 0, opacity: 1 - mix}}>
          <VideoAt src={DUO_SRC} time={from} rate={SRC_RATE} style={fill} />
        </div>
      )}
    </>
  );
};

/** A box and a ref tag over one control of the web page, in the inner screen's coordinates. */
const WebTag: React.FC<{st: number; from: number; to: number; y0: number; y1: number; label: string}> = ({st, from, to, y0, y1, label}) => {
  if (st < from - 0.05 || st > to + 0.3) return null;
  const o = Math.min(tw(st, from, from + 0.3), tw(st, to, to + 0.25, 1, 0));
  const x = simX(0.055), w = simX(0.945) - x, y = simY(y0), h = simY(y1) - y;
  return (
    <div style={{position: 'absolute', left: x - 5, top: y - 5, width: w + 10, height: h + 10, borderRadius: 10, border: `3px solid ${C.cyan}`, boxShadow: `0 0 22px rgba(34,211,238,0.6)`, opacity: o}}>
      <div style={{position: 'absolute', left: -62, top: h / 2 - 12, padding: '3px 10px', borderRadius: 8, background: C.cyan, color: '#04121a', fontFamily: MONO, fontWeight: 500, fontSize: 20}}>{label}</div>
    </div>
  );
};

const Rows: React.FC<{t: number; from: number; to: number}> = ({t, from, to}) => {
  if (t < from - 0.05 || t > to + 0.4) return null;
  const o = Math.min(tw(t, from, from + 0.5), tw(t, to, to + 0.35, 1, 0));
  const rows = ['w3|typeText|text-field|Email|', 'w4|typeText|text-field|Password|', 'w5|tap|button|Sign in|'];
  return (
    <div style={{position: 'absolute', left: 1500, top: 250, width: 390, opacity: o, transform: `translateX(${tw(t, from, from + 0.6, 30, 0)}px)`}}>
      <div style={{fontFamily: MONO, fontSize: 19, color: C.text, padding: '14px 18px', borderRadius: 14, background: 'rgba(12,16,23,0.9)', border: '1px solid rgba(34,211,238,0.35)', whiteSpace: 'pre'}}>
        <span style={{color: C.cyan}}>❯ </span>axe describe-ui --agent --web
      </div>
      <div style={{marginTop: 14, fontFamily: MONO, fontSize: 19, lineHeight: 1.9, color: '#B6C2D6', whiteSpace: 'pre'}}>
        {rows.map((r, i) => (
          <div key={r} style={{opacity: tw(t, from + 0.5 + i * 0.18, from + 0.8 + i * 0.18)}}>
            <span style={{color: C.cyan}}>{r.slice(0, 2)}</span>
            {r.slice(2)}
          </div>
        ))}
      </div>
    </div>
  );
};

export const Out: React.FC = () => {
  const t = useT();
  const st = t - T0; // story time
  const P = PHASE_AT;
  const E = PHASE_END;

  // The Mac from the first scene shrinks to the left and fades as the Duo takes over.
  const macScale = tw(t, 0, 1.6, 1, 0.42, inOut);
  const macX = tw(t, 0, 1.6, 960 - MAC_W / 2, 90, inOut);
  const macY = tw(t, 0, 1.6, 70, 330, inOut);
  const macO = tw(t, GO - 0.2, GO + 0.9, 1, 0, Easing.in(Easing.quad));

  // The Duo: travels folded, then turns and opens.
  const travel = tw(t, 0.7, GO, 0, 1, inOut);
  const open = tw(t, GO + 0.2, GO + 2.3, 0, 1, inOut);
  const angle = open * 180;
  const settle = tw(t, GO, T0, 0, 1, inOut);
  let scale = 0.5 + 0.08 * travel + (1 - 0.58) * settle;
  let rotY = -62 + 34 * travel + 28 * settle + Math.sin(Math.min(1, open) * Math.PI) * 16;
  let rotX = 10 - 10 * settle;
  let rotZ = -6 + 6 * settle;
  let cx = 700 + (1180 - 700) * travel + (960 - 1180) * settle;
  let cy = 520 - 40 * travel + (60 + BODY_H / 2 - 480) * settle;
  const appear = tw(t, 0.6, 1.3);

  // The camera, once open: how far it pushes in and where the Duo sits.
  const push = (a: number, b: number, hold = 0.9) => Math.min(tw(st, a, a + hold, 0, 1, inOut), tw(st, b - hold, b, 1, 0, inOut));
  const web = push(P.web - 0.2, E.booked + 0.1);
  const you = push(P.you, E.you + 0.2);
  const reveal = push(storyOf(151.5), storyOf(170.5) + 0.4, 0.8);
  if (st > 0) {
    scale = 1 + 0.26 * web + 0.2 * you + 0.22 * reveal;
    cx = 960 - 190 * web + 150 * you - 150 * reveal;
    cy = 60 + BODY_H / 2 + 46 * web + 40 * you + 40 * reveal;
    rotY = 0;
    rotX = 0;
    rotZ = 0;
  }
  const exit = tw(t, OUT - 0.5, OUT, 1, 0, Easing.in(Easing.quad));

  // The Mac at home, beside the Duo, while the person touches the mirror.
  const {src} = srcAt(Math.max(0, st));

  return (
    <AbsoluteFill style={{opacity: exit}}>
      {t < GO + 1 && (
        <div style={{position: 'absolute', left: macX, top: macY, transform: `scale(${macScale})`, transformOrigin: '0 0', opacity: macO}}>
          <Mac simTime={homeSim(HOME + t)} lines={HOME_LINES.map((l) => ({...l, at: l.at - HOME}))} />
        </div>
      )}
      {/* The way out */}
      {t < GO + 0.8 && (
        <svg width={1920} height={1080} style={{position: 'absolute', inset: 0, opacity: tw(t, 0.8, 1.4) * tw(t, GO - 0.3, GO + 0.6, 1, 0)}}>
          <path d="M 600 560 C 800 440, 1000 620, 1180 480" stroke={C.cyan} strokeOpacity={0.5} strokeWidth={3} strokeDasharray="4 14" strokeLinecap="round" fill="none" />
        </svg>
      )}
      <div style={{position: 'absolute', left: cx - BODY_W, top: cy - BODY_H / 2, transform: `scale(${scale})`, transformOrigin: '50% 50%', opacity: appear}}>
        <Duo
          screenH={SCREEN_H}
          angle={angle}
          rotateX={rotX}
          rotateY={rotY}
          rotateZ={rotZ}
          glare={false}
          outer={<LockScreen />}
          inner={<DuoScreen st={st} />}
          innerOverlay={
            <>
              <WebTag st={st} from={P.web + 0.35} to={storyOf(59.0)} y0={0.342} y1={0.397} label="w3" />
              <WebTag st={st} from={P.web + 0.5} to={storyOf(59.0)} y0={0.442} y1={0.496} label="w4" />
              <WebTag st={st} from={P.web + 0.65} to={storyOf(59.0)} y0={0.523} y1={0.577} label="w5" />
            </>
          }
        />
      </div>
      <Rows t={st} from={P.web + 0.5} to={E.web - 0.3} />

      {st > P.you - 0.2 && st < E.you + 0.8 && (
        <div style={{position: 'absolute', left: 30, top: 300, opacity: Math.min(tw(st, P.you + 0.3, P.you + 1.0), tw(st, E.you - 0.1, E.you + 0.5, 1, 0)), transform: `translateX(${tw(st, P.you + 0.3, P.you + 1.1, -40, 0)}px)`}}>
          <div style={{transform: 'scale(0.36)', transformOrigin: '0 0', width: MAC_W, height: MAC_H}}>
            <Mac simTime={src + MAC_LAG} lines={HOME_LINES.map((l) => ({...l, at: -10}))} />
          </div>
          <div style={{position: 'absolute', left: 0, top: MAC_H * 0.36 + 14, width: MAC_W * 0.36, textAlign: 'center', fontFamily: MONO, fontSize: 19, letterSpacing: '0.14em', textTransform: 'uppercase', color: C.sub}}>
            Your Mac, at home
          </div>
        </div>
      )}

      <Caption t={t} from={0.9} to={GO - 0.1} text="You go out. It keeps working." />
      <Caption t={t} from={GO + 0.3} to={T0 + P.open + 2.2} text="Open your Duo." />
      <Caption t={st} from={P.open + 2.7} to={E.open - 0.15} text="Your agent on one side. Your simulator on the other." />
      <Caption t={st} from={P.ask + 0.2} to={E.ask - 0.15} text="Ask from wherever you are. Watch it work, live." />
      <Caption t={st} from={P.web + 0.2} to={E.web - 0.15} eyebrow="New in AXe 2.1" text="Your agent can read and use web pages." sub="Sign-in sheets, Safari, web views in any app." />
      <Caption t={st} from={P.booked + 0.2} to={E.booked - 0.15} text="Signed in, and booked." />
      <Caption t={st} from={P.you + 0.2} to={E.you - 0.15} text="Your turn. Swipe, pinch, tap." sub="One simulator, shared by you and your agent." />
      <Caption t={st} from={P.change + 0.2} to={storyOf(158.5) - 0.15} text="Say what to change. Watch it happen." />
      <Caption t={st} from={storyOf(158.5) + 0.2} to={STORY + 0.2} text="Then try it yourself." />

      <div style={{position: 'absolute', left: 34, bottom: 34, width: 330, fontFamily: FONT, fontSize: 15, color: C.muted, opacity: tw(st, 0.5, 1.2), lineHeight: 1.4}}>
        One take, recorded on an iPhone Duo and on the Mac. Shown faster than real time, with waiting cut. Device bodies illustrated.
      </div>
    </AbsoluteFill>
  );
};

// ───────────────────────────── 8. Why it stays yours ─────────────────────────────
export const WHY = 7.0;
export const Why: React.FC = () => {
  const t = useT();
  const lines = ['Everything runs on your Mac.', 'Pair once with a code.', 'Encrypted end to end.', 'Works with any agent that can run a command.'];
  const dash = tw(t, 0.6, 1.6, 0, 1, inOut);
  const node = (x: number, label: string, sub: string, at: number, w: number, h: number, r: number) => (
    <Fade at={at} style={{position: 'absolute', left: x - 150, top: 330, width: 300, display: 'flex', flexDirection: 'column', alignItems: 'center'}}>
      <div style={{width: w, height: h, borderRadius: r, border: `3px solid ${C.cyanLight}`, background: 'rgba(12,16,23,0.9)', boxShadow: '0 0 50px rgba(34,211,238,0.18)'}} />
      <div style={{fontFamily: FONT, fontWeight: 500, fontSize: 30, color: C.text, marginTop: 20}}>{label}</div>
      <div style={{fontFamily: MONO, fontSize: 19, color: C.sub, marginTop: 6}}>{sub}</div>
    </Fade>
  );
  return (
    <Scene dur={WHY}>
      <div style={{position: 'absolute', left: 120, top: 90, right: 120}}>
        <Rise text="It stays yours." at={0.1} style={{fontFamily: FONT, fontWeight: 600, fontSize: 88, letterSpacing: '-0.035em', color: C.text}} gradientWords={['yours.']} />
      </div>
      <div style={{position: 'absolute', left: 120, top: 250, width: 860, height: 420}}>
        <svg width={860} height={420} style={{position: 'absolute', inset: 0}}>
          <path d="M 250 170 L 610 170" stroke={C.cyan} strokeWidth={4} strokeLinecap="round" fill="none" strokeDasharray={360} strokeDashoffset={360 * (1 - dash)} />
          <path d="M 240 120 C 330 -10, 530 -10, 620 120" stroke={C.sub} strokeWidth={3} strokeLinecap="round" fill="none" strokeDasharray="3 13" opacity={tw(t, 1.6, 2.3)} />
        </svg>
        <div style={{position: 'absolute', left: 0, top: -250}}>
          {node(150, 'Your Mac', 'axe mirror', 0.4, 190, 124, 14)}
          {node(710, 'iPhone or iPad', 'AXe Mirror', 0.6, 150, 124, 22)}
        </div>
        <Fade at={1.2} style={{position: 'absolute', left: 250, top: 184, width: 360, textAlign: 'center', whiteSpace: 'nowrap'}}>
          <div style={{fontFamily: MONO, fontSize: 19, color: C.cyan}}>direct when it can</div>
        </Fade>
        <Fade at={1.8} style={{position: 'absolute', left: 250, top: -16, width: 360, textAlign: 'center', whiteSpace: 'nowrap'}}>
          <div style={{fontFamily: MONO, fontSize: 19, color: C.sub}}>a relay when it cannot</div>
        </Fade>
      </div>
      <div style={{position: 'absolute', left: 1080, top: 300, width: 740}}>
        {lines.map((l, i) => (
          <Fade key={l} at={1.3 + i * 0.75} style={{display: 'flex', alignItems: 'baseline', gap: 20, marginBottom: 30}}>
            <div style={{width: 12, height: 12, borderRadius: 6, background: C.cyan, flexShrink: 0, transform: 'translateY(-6px)'}} />
            <div style={{fontFamily: FONT, fontWeight: 500, fontSize: 42, lineHeight: 1.18, letterSpacing: '-0.02em', color: C.text}}>{l}</div>
          </Fade>
        ))}
      </div>
    </Scene>
  );
};

// ───────────────────────────── 9. End card ─────────────────────────────
export const END = 6.5;
export const End: React.FC = () => {
  const t = useT();
  const glow = 0.5 + 0.5 * Math.sin(t * 2.2);
  const cmd = 'brew install cameroncooke/axe/axe';
  const n = Math.round(tw(t, 1.6, 2.5, 0, cmd.length, (x) => x));
  const h = 130;
  const fs = (h * (276 / 315)) / 0.715;
  return (
    <AbsoluteFill style={{opacity: Math.min(tw(t, 0, 0.5, 0, 1, Easing.out(Easing.quad)), tw(t, END - 0.9, END - 0.1, 1, 0, Easing.in(Easing.quad)))}}>
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
        <div style={{display: 'flex', alignItems: 'center', gap: 44, transform: 'translateY(-200px)'}}>
          <Img src={staticFile('icon.png')} style={{width: 190, height: 190, opacity: tw(t, 0.1, 1.0), transform: `scale(${tw(t, 0.1, 1.2, 0.8, 1, outExpo)})`, filter: `drop-shadow(0 0 ${26 + glow * 26}px rgba(34,211,238,0.45))`}} />
          <div style={{display: 'flex', alignItems: 'flex-end', gap: h * 0.16}}>
            <Img src={staticFile('axe-text.png')} style={{height: h, display: 'block', opacity: tw(t, 0.3, 1.2)}} />
            <div style={{fontFamily: FONT, fontWeight: 600, fontSize: fs, lineHeight: 1, letterSpacing: '-0.05em', marginBottom: h * (24 / 315) - fs * 0.1575 + fs * 0.008, backgroundImage: GRAD, WebkitBackgroundClip: 'text', backgroundClip: 'text', color: 'transparent', paddingRight: fs * 0.05, opacity: tw(t, 0.5, 1.4)}}>
              2.1
            </div>
          </div>
        </div>
        <div style={{position: 'absolute', top: 470, width: '100%', display: 'flex', justifyContent: 'center'}}>
          <Rise text="Your agent's simulator, wherever you are." at={0.8} style={{fontFamily: FONT, fontSize: 46, color: C.text, letterSpacing: '-0.01em', justifyContent: 'center'}} />
        </div>
        <div style={{position: 'absolute', top: 590, width: '100%', display: 'flex', justifyContent: 'center', opacity: tw(t, 1.4, 1.9)}}>
          <div style={{fontFamily: MONO, fontSize: 34, color: C.text, padding: '22px 38px', borderRadius: 20, background: 'rgba(12,16,23,0.85)', border: '1px solid rgba(34,211,238,0.35)', boxShadow: '0 0 50px rgba(34,211,238,0.12)', whiteSpace: 'pre'}}>
            <span style={{color: C.cyan}}>❯ </span>
            {cmd.slice(0, n)}
            <span style={{opacity: 0}}>{cmd.slice(n)}</span>
          </div>
        </div>
        <Fade at={2.6} style={{position: 'absolute', top: 730, width: '100%', textAlign: 'center'}}>
          <div style={{fontFamily: FONT, fontSize: 34, color: C.text}}>
            AXe Mirror for iPhone and iPad: free on the App Store
          </div>
          <div style={{fontFamily: FONT, fontSize: 30, color: C.sub, marginTop: 10, letterSpacing: '0.02em'}}>axe-cli.com/mirror</div>
        </Fade>
        <Fade at={3.3} style={{position: 'absolute', top: 900, width: '100%', textAlign: 'center'}}>
          <div style={{fontFamily: FONT, fontSize: 24, color: C.muted}}>
            Also new: <span style={{fontFamily: MONO}}>axe serve</span>, typing on your keyboard's layout, and iPhone Duo fixes.
          </div>
        </Fade>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

export const FILM21: [string, number, React.FC][] = [
  ['At home', HOME, Home],
  ['Out with the Duo', OUT, Out],
  ['Why it stays yours', WHY, Why],
  ['End card', END, End],
];
/** Where each beat of the story starts, in seconds from the start of the film (for the music). */
export const FILM21_CUTS = [
  HOME,
  HOME + GO,
  HOME + T0 + PHASE_AT.ask,
  HOME + T0 + PHASE_AT.web,
  HOME + T0 + PHASE_AT.you,
  HOME + T0 + PHASE_AT.change,
  HOME + OUT,
  HOME + OUT + WHY,
];
