import React from 'react';
import {AbsoluteFill, Easing, Img, staticFile} from 'remotion';
import {C, Chip, Eyebrow, Fade, FONT, Footnote, GRAD, inOut, Line, MONO, Ripple, Rise, Scene, Terminal, tw, useT, VideoAt} from './lib';
import {Duo, Phone} from './hardware';
import agentLog from './agent-log.json';
import car from './car.json';

const H1: React.CSSProperties = {fontFamily: FONT, fontWeight: 600, fontSize: 104, lineHeight: 1.02, letterSpacing: '-0.035em', color: C.text};
const SUB: React.CSSProperties = {fontFamily: FONT, fontWeight: 400, fontSize: 34, lineHeight: 1.35, color: C.sub, letterSpacing: '-0.01em'};


/**
 * The AXe wordmark with "2.0" set on the same baseline and at the same cap height.
 * Measured from axe-text.png (791×315): the letters span rows 15–291, so the baseline is 24/315 of the
 * height above the image's bottom edge. Rubik's digits are 0.7 em tall and, at line-height 1, its
 * baseline is 0.1575 em above the bottom of the line box.
 */
const Lockup: React.FC<{h: number; word: React.CSSProperties; two: React.CSSProperties}> = ({h, word, two}) => {
  const fs = (h * (276 / 315)) / 0.715; // 0.7 em plus the round digits' overshoot
  return (
    <div style={{display: 'flex', alignItems: 'flex-end', gap: h * 0.16}}>
      <Img src={staticFile('axe-text.png')} style={{height: h, display: 'block', ...word}} />
      <div
        style={{
          fontFamily: FONT,
          fontWeight: 600,
          fontSize: fs,
          lineHeight: 1,
          letterSpacing: '-0.05em',
          marginBottom: h * (24 / 315) - fs * 0.1575 + fs * 0.008,
          backgroundImage: GRAD,
          WebkitBackgroundClip: 'text',
          backgroundClip: 'text',
          color: 'transparent',
          paddingRight: fs * 0.05,
          ...two,
        }}
      >
        2.0
      </div>
    </div>
  );
};

// ───────────────────────────── Intro ─────────────────────────────
export const INTRO = 5.0; // every scene length is a whole number of beats at 120 BPM (0.5 s)
export const Intro: React.FC = () => {
  const t = useT();
  const icon = tw(t, 0.15, 1.5);
  const glow = 0.5 + 0.5 * Math.sin(t * 2.2);
  const two = tw(t, 1.0, 2.0);
  return (
    <Scene dur={INTRO}>
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
        <div style={{display: 'flex', alignItems: 'center', gap: 56, transform: `translateY(-30px) scale(${tw(t, 0, INTRO, 0.97, 1.03, (x) => x)})`}}>
          <Img
            src={staticFile('icon.png')}
            style={{
              width: 300,
              height: 300,
              opacity: icon,
              transform: `scale(${0.7 + icon * 0.3}) rotate(${(1 - icon) * -8}deg)`,
              filter: `blur(${(1 - icon) * 16}px) drop-shadow(0 0 ${30 + glow * 30}px rgba(34,211,238,${0.35 + glow * 0.2}))`,
            }}
          />
          <Lockup
            h={190}
            word={{opacity: tw(t, 0.6, 1.5), transform: `translateX(${tw(t, 0.6, 1.6, 40, 0)}px)`, filter: `blur(${tw(t, 0.6, 1.4, 12, 0)}px)`}}
            two={{opacity: two, transform: `translateY(${(1 - two) * 50}px) scale(${0.9 + two * 0.1})`, filter: `blur(${(1 - two) * 14}px)`}}
          />
        </div>
        <div style={{position: 'absolute', top: 760, width: '100%', display: 'flex', justifyContent: 'center'}}>
          <Rise text="iOS automation. Rebuilt from the tap up." at={2.0} style={{...SUB, fontSize: 44, color: C.text, justifyContent: 'center'}} />
        </div>
      </AbsoluteFill>
    </Scene>
  );
};

// ───────────────────────────── What's new ─────────────────────────────
// Four fast beats, then all four together: the headline features before each gets its own section.
const NEW_ITEMS: {big: string; small: string; mono: string}[] = [
  {big: 'Real devices.', small: 'Your iPhone and iPad, by hardware UDID', mono: 'axe tap --udid $DEVICE'},
  {big: 'iPhone Duo.', small: 'Both screens, every fold and rotation', mono: 'axe hinge set open'},
  {big: 'Agent mode.', small: 'Stateful, checked actions for AI agents', mono: 'axe tap --agent --ref e9'},
  {big: '12× faster.', small: 'A tap in 0.08 s, down from about 1 s', mono: 'axe tap  →  0.08 s'},
];
const BEAT = 1.0; // two beats of the music per feature
export const NEW_LEAD = 1.0;
const BEATS_END = NEW_LEAD + NEW_ITEMS.length * BEAT;
export const WHATSNEW = BEATS_END + 3.0;
export const WhatsNew: React.FC = () => {
  const t = useT();
  const grid = tw(t, BEATS_END, BEATS_END + 0.6);
  return (
    <Scene dur={WHATSNEW}>
      <div style={{position: 'absolute', left: 0, right: 0, top: 120, textAlign: 'center', opacity: tw(t, 0, 0.4)}}>
        <div style={{fontFamily: MONO, fontSize: 24, letterSpacing: '0.3em', textTransform: 'uppercase', color: C.cyan}}>What’s new in 2.0</div>
      </div>
      {/* One feature at a time, full width */}
      {NEW_ITEMS.map((item, i) => {
        const a = NEW_LEAD + i * BEAT;
        if (t < a - 0.05 || t > a + BEAT + 0.2) return null;
        const inP = tw(t, a, a + 0.32);
        const outP = tw(t, a + BEAT - 0.16, a + BEAT, 0, 1, Easing.in(Easing.cubic));
        return (
          <AbsoluteFill key={item.big} style={{alignItems: 'center', justifyContent: 'center', opacity: inP * (1 - outP)}}>
            <div style={{fontFamily: MONO, fontSize: 30, color: C.muted, marginBottom: 18, transform: `translateY(${(1 - inP) * 20}px)`}}>
              0{i + 1} <span style={{color: 'rgba(91,107,132,0.5)'}}>/ 04</span>
            </div>
            <div
              style={{
                fontFamily: FONT,
                fontWeight: 600,
                fontSize: 220,
                letterSpacing: '-0.045em',
                lineHeight: 1,
                backgroundImage: i % 2 ? GRAD : 'linear-gradient(180deg, #fff, #cbd5e1)',
                WebkitBackgroundClip: 'text',
                backgroundClip: 'text',
                color: 'transparent',
                transform: `scale(${1.18 - inP * 0.18 - outP * 0.06}) translateY(${(1 - inP) * 30}px)`,
                filter: `blur(${(1 - inP) * 18 + outP * 14}px)`,
                paddingBottom: 20,
              }}
            >
              {item.big}
            </div>
          </AbsoluteFill>
        );
      })}
      {/* All four, to read at a glance */}
      {t >= BEATS_END - 0.05 && (
        <div style={{position: 'absolute', left: 120, right: 120, top: 250, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 30, opacity: grid}}>
          {NEW_ITEMS.map((item, i) => {
            const p = tw(t, BEATS_END + i * 0.07, BEATS_END + i * 0.07 + 0.6);
            return (
              <div
                key={item.big}
                style={{
                  height: 300,
                  borderRadius: 34,
                  padding: '44px 50px',
                  background: 'linear-gradient(160deg, rgba(23,29,42,0.92), rgba(12,16,23,0.8))',
                  border: `1px solid ${C.line}`,
                  boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.06)',
                  opacity: p,
                  transform: `scale(${0.94 + p * 0.06}) translateY(${(1 - p) * 26}px)`,
                  display: 'flex',
                  flexDirection: 'column',
                  justifyContent: 'space-between',
                }}
              >
                <div>
                  <div style={{fontFamily: FONT, fontWeight: 600, fontSize: 92, letterSpacing: '-0.04em', lineHeight: 1, backgroundImage: GRAD, WebkitBackgroundClip: 'text', backgroundClip: 'text', color: 'transparent', paddingBottom: 8}}>
                    {item.big}
                  </div>
                  <div style={{fontFamily: FONT, fontSize: 32, color: C.text, marginTop: 10}}>{item.small}</div>
                </div>
                <div style={{fontFamily: MONO, fontSize: 24, color: C.sub}}>
                  <span style={{color: C.cyan}}>❯ </span>
                  {item.mono}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </Scene>
  );
};

// ───────────────────────────── Speed ─────────────────────────────
export const SPEED = 9.0;
const Lane: React.FC<{label: string; secs: number; start: number; y: number; hero?: boolean; value: string}> = ({label, secs, start, y, hero, value}) => {
  const t = useT();
  const p = tw(t, start, start + secs, 0, 1, (x) => x);
  const done = t >= start + secs;
  const trackW = 1180;
  return (
    <Fade at={0.9} style={{position: 'absolute', left: 120, top: y, width: 1680}}>
      <div style={{display: 'flex', alignItems: 'center', gap: 36}}>
        <div style={{width: 190, fontFamily: MONO, fontSize: 28, color: hero ? C.text : C.sub}}>{label}</div>
        <div style={{position: 'relative', width: trackW, height: 18, borderRadius: 9, background: 'rgba(148,163,184,0.10)'}}>
          <div
            style={{
              position: 'absolute',
              left: 0,
              top: 0,
              bottom: 0,
              width: trackW * p,
              borderRadius: 9,
              background: hero ? GRAD : 'linear-gradient(90deg, #334155, #64748B)',
              boxShadow: hero ? `0 0 34px rgba(34,211,238,0.7)` : 'none',
            }}
          />
          <div
            style={{
              position: 'absolute',
              left: trackW * p - 15,
              top: -6,
              width: 30,
              height: 30,
              borderRadius: 15,
              background: hero ? '#fff' : '#94A3B8',
              boxShadow: hero ? `0 0 30px ${C.cyan}` : 'none',
              opacity: t >= start ? 1 : 0,
            }}
          />
        </div>
        <div
          style={{
            fontFamily: FONT,
            fontWeight: 600,
            fontSize: 46,
            letterSpacing: '-0.02em',
            color: hero ? C.cyanLight : C.sub,
            opacity: done ? tw(t, start + secs, start + secs + 0.25) : 0,
            whiteSpace: 'nowrap',
          }}
        >
          {value}
        </div>
      </div>
    </Fade>
  );
};
const Stat: React.FC<{at: number; name: string; now: string; was: string; plain?: boolean}> = ({at, name, now, was, plain}) => (
  <Fade at={at} style={{flex: 1}}>
    <div
      style={{
        padding: '34px 38px',
        borderRadius: 26,
        background: 'linear-gradient(180deg, rgba(17,22,32,0.85), rgba(12,16,23,0.7))',
        border: `1px solid ${C.line}`,
      }}
    >
      <div style={{fontFamily: MONO, fontSize: 24, color: C.sub}}>{name}</div>
      <div style={{display: 'flex', alignItems: 'baseline', gap: 20, marginTop: 10}}>
        <div style={{fontFamily: FONT, fontWeight: 600, fontSize: 88, letterSpacing: '-0.04em', backgroundImage: GRAD, WebkitBackgroundClip: 'text', backgroundClip: 'text', color: 'transparent'}}>
          {now}
        </div>
        <div style={{fontFamily: FONT, fontSize: 28, color: plain ? C.sub : C.muted, textDecoration: plain ? 'none' : 'line-through', textDecorationColor: 'rgba(91,107,132,0.7)'}}>{was}</div>
      </div>
    </div>
  </Fade>
);
export const Speed: React.FC = () => {
  const t = useT();
  const go = 2.0;
  return (
    <Scene dur={SPEED}>
      <div style={{position: 'absolute', left: 120, top: 110}}>
        <Eyebrow at={0.1}>Performance</Eyebrow>
        <Rise text="A tap, in 80 milliseconds." at={0.25} style={H1} gradientWords={['80', 'milliseconds.']} />
      </div>
      <Fade at={1.2} style={{position: 'absolute', left: 120, top: 388}}>
        <div style={{...SUB, fontSize: 28}}>
          One <span style={{fontFamily: MONO, color: C.text}}>axe tap</span>, played back in real time:
        </div>
      </Fade>
      <Lane label="v1.8.0" secs={1.0} start={go} y={470} value="~1 s" />
      <Lane label="v2.0" secs={0.08} start={go} y={560} hero value="0.08 s" />
      <div style={{position: 'absolute', left: 120, right: 120, top: 690, display: 'flex', gap: 28}}>
        <Stat at={3.9} name="tap" now="12×" was="faster" plain />
        <Stat at={4.15} name="drag" now="0.9 s" was="2.5 s" />
        <Stat at={4.4} name="describe-ui" now="0.3 s" was="1.1–1.9 s" />
      </div>
      <Footnote at={4.8}>Single commands, v2.0.0 against v1.8.0, measured on an iPhone 18 Pro simulator.</Footnote>
      <div style={{display: 'none'}}>{t}</div>
    </Scene>
  );
};

// ───────────────────────────── Agent mode ─────────────────────────────
export const AGENT = 13.0;
const AG_START = 2.8; // source seconds at scene time AG_T0
const AG_RATE = 1.8;
const AG_T0 = 1.1;
const short = (s: string, n: number) => (s.length > n ? s.slice(0, n - 1) + '…' : s);
const agentLines = (): Line[] => {
  const rec = (agentLog as {rec: number}).rec;
  const out: Line[] = [];
  (agentLog as {events: {shown: string; start: number; end: number; out: string}[]}).events.forEach((e, i) => {
    const s = AG_T0 + (e.start - rec - AG_START) / AG_RATE;
    const d = AG_T0 + (e.end - rec - AG_START) / AG_RATE;
    const reply = JSON.parse(e.out);
    const cap = reply.data.capture;
    const cmd = e.shown.replace(' --view navigation', '').replace('--agent --ref', '--agent --snapshot-id $SNAP --ref').replace("'London' --agent --focus --ref", "'London' --agent --focus --snapshot-id $SNAP --ref");
    if (i > 0) out.push({at: s - 0.02, kind: 'gap'});
    out.push({at: Math.max(0.3, s - 0.35), kind: 'cmd', text: short(cmd, 58), typeDur: 0.32});
    const act = reply.data.action;
    if (act) out.push({at: d, kind: 'ok', text: `✓ ${act.outcome} · ${act.enqueuedEventCount} events`});
    if (reply.data.batch) out.push({at: d, kind: 'ok', text: `✓ focus + type · ${reply.data.batch.completedSteps} steps completed`});
    (cap.rows as string[]).slice(0, i === 0 ? 2 : 3).forEach((r, k) => out.push({at: d + 0.05 * (k + 1), kind: 'out', text: short(r, 58)}));
    out.push({at: d + 0.22, kind: 'dim', text: `  screen ${cap.screenHash.slice(0, 8)} · ${cap.rows.length} rows · new snapshot`});
  });
  return out;
};
export const Agent: React.FC = () => {
  const t = useT();
  const src = Math.min(22.9, AG_START + AG_RATE * Math.max(0, t - AG_T0));
  const lines = React.useMemo(agentLines, []);
  const float = Math.sin(t * 0.9) * 6;
  const pin = (at: number, text: string, y: number) => (
    <Fade at={at} style={{position: 'absolute', left: 120, top: y}}>
      <div style={{display: 'flex', alignItems: 'center', gap: 16, fontFamily: FONT, fontSize: 30, color: C.text}}>
        <div style={{width: 10, height: 10, borderRadius: 5, background: C.cyan, boxShadow: `0 0 16px ${C.cyan}`}} />
        {text}
      </div>
    </Fade>
  );
  return (
    <Scene dur={AGENT}>
      <div style={{position: 'absolute', left: 120, top: 84}}>
        <Eyebrow at={0.1}>Agent mode</Eyebrow>
        <Rise text="Every action checked." at={0.2} style={{...H1, fontSize: 88}} />
        <Rise text="Every reply, the new screen." at={0.55} style={{...H1, fontSize: 88}} gradientWords={['new', 'screen.']} />
      </div>
      <div style={{position: 'absolute', left: 120, top: 372}}>
        <Fade at={0.9}>
          <Terminal lines={lines} width={1020} height={470} title="axe — agent mode" fontSize={21} />
        </Fade>
      </div>
      {pin(3.2, 'Stateful refs. A stale target is refused before input.', 880)}
      {pin(5.2, 'No read after each action. No model. No API key.', 934)}
      <div style={{position: 'absolute', left: 1330, top: 70 + float}}>
        <Fade at={0.5} y={60} dur={1.1}>
          <Phone height={940} rotateY={-13} rotateX={3}>
            <VideoAt src="agent.mp4" time={src} style={{width: '100%', height: '100%', objectFit: 'cover'}} />
          </Phone>
        </Fade>
      </div>
      <Footnote at={1.5} style={{left: 1220, right: 60, bottom: 30, textAlign: 'right'}}>
        Real commands and replies. Screen recording at {AG_RATE}× speed.
      </Footnote>
    </Scene>
  );
};

// ───────────────────────────── Benchmark ─────────────────────────────
export const BENCH = 10.0;
const TASKS = [
  {name: 'Weather', axe: 65, rs: 100, fd: 129},
  {name: 'Contacts', axe: 65, rs: 158, fd: 181},
  {name: 'Reminders', axe: 65, rs: 97, fd: 87},
];
const Bar: React.FC<{label: string; v: number; max: number; at: number; hero?: boolean}> = ({label, v, max, at, hero}) => {
  const t = useT();
  const p = tw(t, at, at + 1.1);
  const full = 250;
  return (
    <div style={{display: 'flex', alignItems: 'center', gap: 16, height: 46}}>
      <div style={{width: 128, fontFamily: FONT, fontSize: 23, fontWeight: hero ? 600 : 400, color: hero ? C.text : C.sub, textAlign: 'right'}}>{label}</div>
      <div
        style={{
          height: hero ? 30 : 24,
          width: Math.max(4, (v / max) * full * p),
          borderRadius: 8,
          background: hero ? GRAD : 'linear-gradient(90deg, #2A3244, #465569)',
          boxShadow: hero ? '0 0 28px rgba(34,211,238,0.45)' : 'none',
        }}
      />
      <div style={{fontFamily: FONT, fontWeight: 600, fontSize: hero ? 30 : 24, color: hero ? C.cyanLight : C.sub, opacity: tw(t, at + 0.3, at + 0.8), whiteSpace: 'nowrap'}}>
        {Math.round(v * p)} s
      </div>
    </div>
  );
};
const Fact: React.FC<{at: number; big: string; small: string}> = ({at, big, small}) => (
  <Fade at={at} style={{flex: 1}}>
    <div style={{borderLeft: `2px solid rgba(34,211,238,0.5)`, paddingLeft: 26}}>
      <div style={{fontFamily: FONT, fontWeight: 600, fontSize: 54, letterSpacing: '-0.03em', color: C.text}}>{big}</div>
      <div style={{fontFamily: FONT, fontSize: 25, color: C.sub, marginTop: 4, lineHeight: 1.3}}>{small}</div>
    </div>
  </Fade>
);
export const Bench: React.FC = () => {
  return (
    <Scene dur={BENCH}>
      <div style={{position: 'absolute', left: 120, top: 96}}>
        <Eyebrow at={0.1}>Agent benchmark</Eyebrow>
        <Rise text="Fastest on every task." at={0.25} style={H1} gradientWords={['Fastest']} />
        <Fade at={0.9} style={{marginTop: 22}}>
          <div style={SUB}>An AI agent, three real apps, each tool with its own official skill.</div>
        </Fade>
      </div>
      <div style={{position: 'absolute', left: 120, right: 120, top: 440, display: 'flex', gap: 30}}>
        {TASKS.map((task, i) => (
          <Fade key={task.name} at={1.2 + i * 0.18} style={{flex: 1}}>
            <div style={{padding: '30px 30px 26px', borderRadius: 26, background: 'linear-gradient(180deg, rgba(17,22,32,0.85), rgba(12,16,23,0.7))', border: `1px solid ${C.line}`}}>
              <div style={{fontFamily: MONO, fontSize: 22, color: C.sub, letterSpacing: '0.12em', textTransform: 'uppercase', marginBottom: 16}}>{task.name} · time</div>
              <Bar label="AXe" v={task.axe} max={181} at={1.6 + i * 0.18} hero />
              <Bar label="RocketSim" v={task.rs} max={181} at={1.8 + i * 0.18} />
              <Bar label="FlowDeck" v={task.fd} max={181} at={2.0 + i * 0.18} />
            </div>
          </Fade>
        ))}
      </div>
      <div style={{position: 'absolute', left: 120, right: 120, top: 760, display: 'flex', gap: 40}}>
        <Fact at={3.6} big="Up to 2.8× faster" small="Contacts: 65 s against 158 s and 181 s" />
        <Fact at={3.9} big="Fewest calls" small="on all three apps: 10 against 30 and 49 on Contacts" />
        <Fact at={4.2} big="9 of 9 passed" small="graded from returned UI state, with no screenshots" />
      </div>
      <Footnote at={4.6}>
        Averages of 3 runs per tool and task. Claude Code with claude-sonnet-5-5 on an iPhone 18 Pro simulator, iOS 27.2. RocketSim 16.8.0, FlowDeck 1.34.0. AXe’s own benchmark;
        method, per-run figures and disclosures are in benchmarks/results in the repository.
      </Footnote>
    </Scene>
  );
};

// ───────────────────────────── iPhone Duo ─────────────────────────────
export const DUO = 14.0;
const D_T0 = 2.8;
const D_RATE = 2;
const D_SRC0 = 4.9;
export const DuoScene: React.FC = () => {
  const t = useT();
  // Hinge angle AXe reports: 0 closed, 180 open.
  let angle = 0;
  if (t < 7.9) angle = tw(t, 1.5, 2.8, 0, 180, inOut);
  else if (t < 9.9) angle = tw(t, 7.95, 8.8, 180, 94.6, inOut);
  else if (t < 11.0) angle = tw(t, 9.95, 10.6, 94.6, 180, inOut);
  else angle = tw(t, 11.0, 12.1, 180, 0, inOut);
  const innerSrc = t < D_T0 ? 3.0 : Math.min(22.5, D_SRC0 + D_RATE * (t - D_T0));
  const tilt = tw(t, 7.9, 8.8, 0, 1, inOut) - tw(t, 9.95, 10.6, 0, 1, inOut);
  const rotY = -16 + Math.sin(t * 0.5) * 3 - tilt * 14;
  const rotX = 7 + tilt * 6;
  const screenH = 560;
  const innerW = (screenH * 951) / 669;
  const k = innerW / 951; // points → px
  const srcAt = (s: number) => D_T0 + (s - D_SRC0) / D_RATE;
  const readout = (label: string, value: string, at: number) => (
    <Fade at={at} style={{width: 400}}>
      <div style={{fontFamily: MONO, fontSize: 19, color: C.muted, letterSpacing: '0.14em', textTransform: 'uppercase'}}>{label}</div>
      <div style={{fontFamily: MONO, fontSize: 30, color: C.text, marginTop: 6, whiteSpace: 'nowrap'}}>{value}</div>
    </Fade>
  );
  const posture = angle < 1 ? 'closed' : angle > 179 ? 'open' : 'partially open';
  const active = angle >= 110 || (t > 2.2 && t < 11.4) ? 'inner  951×669 pt' : 'outer  466×678 pt';
  return (
    <Scene dur={DUO}>
      <div style={{position: 'absolute', left: 120, top: 96, width: 860}}>
        <Eyebrow at={0.1}>iPhone Duo</Eyebrow>
        <Rise text="Two screens." at={0.2} style={H1} />
        <Rise text="Every fold." at={0.5} style={H1} gradientWords={['Every', 'fold.']} />
        <Fade at={1.0} style={{marginTop: 26}}>
          <div style={SUB}>Read the screens, move the hinge and drive whichever display is active.</div>
        </Fade>
      </div>
      <div style={{position: 'absolute', left: 120, top: 600, width: 800, height: 150}}>
        <Chip text="axe hinge set open" from={1.1} to={2.9} />
        <Chip text="axe tap -x 500 -y 84" from={3.0} to={4.9} note="Settings, on the inner screen" />
        <Chip text="axe tap --label Accessibility" from={5.0} to={6.2} />
        <Chip text="axe tap --label Appearance" from={6.3} to={7.6} />
        <Chip text="axe hinge set tabletop" from={7.7} to={9.6} />
        <Chip text="axe hinge set open" from={9.7} to={10.8} />
        <Chip text="axe hinge set closed" from={10.9} to={13.4} />
      </div>
      <div style={{position: 'absolute', left: 120, top: 820, width: 800, display: 'flex', gap: 30}}>
        {readout('axe hinge read', `${angle.toFixed(1)}°, ${posture}`, 1.3)}
        {readout('axe displays', `Active ${active}`, 1.5)}
      </div>
      <div style={{position: 'absolute', left: 1385 - (innerW + 40) / 2, top: 540 - 310}}>
        <Fade at={0.3} y={50} dur={1.1}>
          <Duo
            screenH={screenH}
            angle={angle}
            rotateX={rotX}
            rotateY={rotY}
            outer={<VideoAt src="duo-outer.mp4" time={1.0 + Math.min(t, 2) * 0.5} style={{width: '100%', height: '100%', objectFit: 'cover'}} />}
            inner={<VideoAt src="duo-inner.mp4" time={innerSrc} style={{width: '100%', height: '100%', objectFit: 'cover'}} />}
            innerOverlay={
              <>
                <Ripple at={srcAt(5.75)} x={500 * k} y={84 * k} />
                <Ripple at={srcAt(9.75)} x={160 * k} y={270 * k} />
                <Ripple at={srcAt(12.55)} x={160 * k} y={322 * k} />
              </>
            }
          />
        </Fade>
      </div>
      <Footnote at={1.8} style={{left: 1000, right: 80, textAlign: 'right'}}>
        Screen recordings of the iPhone Duo simulator under AXe, at {D_RATE}× speed. Device body illustrated.
      </Footnote>
    </Scene>
  );
};

// ───────────────────────────── Physical devices ─────────────────────────────
// A real iPhone paints the end-to-end suite's car: scripts/sketch_picture.py playing
// scripts/fixtures/sketch-car.json through `axe draw`. car.json holds the take's timings and log.
export const DEVICE = 15.0;
const PAINT0 = 4.9; // scene seconds over which the painting plays
const PAINT1 = 11.4;
export const Device: React.FC = () => {
  const t = useT();
  const p = tw(t, PAINT0, PAINT1, 0, 1, (x) => x);
  const src = car.a + (car.b - car.a) * p;
  const speed = Math.round((car.b - car.a) / (PAINT1 - PAINT0));
  const lines: Line[] = [
    {at: 1.2, kind: 'cmd', text: 'axe list-devices'},
    {at: 1.8, kind: 'out', text: '00008140-…401C  iPhone 16 Pro Max · 27.2'},
    {at: 2.2, kind: 'gap'},
    {at: 2.2, kind: 'cmd', text: 'axe doctor --udid $DEVICE'},
    {at: 2.85, kind: 'ok', text: '  Paired: ready'},
    {at: 2.95, kind: 'ok', text: '  Developer Mode: ready'},
    {at: 3.05, kind: 'ok', text: '  Connected: ready'},
    {at: 3.15, kind: 'ok', text: '  Unlocked: ready'},
    {at: 3.25, kind: 'ok', text: '  Screenshot service: ready'},
    {at: 3.9, kind: 'gap'},
    {at: 3.9, kind: 'cmd', text: 'scripts/sketch_picture.py axe $DEVICE device sketch-car.json', typeDur: 0.6},
    ...car.log.map((text: string, i: number): Line => ({at: PAINT0 + ((PAINT1 - PAINT0 - 0.3) * i) / car.log.length, kind: 'dim', text: `  ${text}`})),
    {at: PAINT1 + 0.1, kind: 'ok', text: car.painted.replace(/ tools=\S+/, ' …').replace(/ picture=\S+/, '')},
  ];
  const ph = 930;
  const float = Math.sin(t * 0.8) * 6;
  const pulse = (t * 0.55) % 1;
  const fact = (at: number, big: string, small: string) => (
    <Fade at={at} style={{width: 300}}>
      <div style={{fontFamily: FONT, fontWeight: 600, fontSize: 60, letterSpacing: '-0.03em', backgroundImage: GRAD, WebkitBackgroundClip: 'text', backgroundClip: 'text', color: 'transparent'}}>{big}</div>
      <div style={{fontFamily: FONT, fontSize: 25, color: C.sub, marginTop: 2}}>{small}</div>
    </Fade>
  );
  return (
    <Scene dur={DEVICE}>
      <div style={{position: 'absolute', left: 120, top: 84, width: 1100}}>
        <Eyebrow at={0.1}>New in 2.0</Eyebrow>
        <Rise text="Now on real devices." at={0.2} style={H1} gradientWords={['real', 'devices.']} />
        <Fade at={0.9} style={{marginTop: 20}}>
          <div style={SUB}>Your iPhone. Your iPad. The same commands, precise enough to paint.</div>
        </Fade>
      </div>
      <div style={{position: 'absolute', left: 120, top: 400}}>
        <Fade at={0.9}>
          <Terminal lines={lines} width={1010} height={400} title="axe — physical device" fontSize={21} />
        </Fade>
      </div>
      <div style={{position: 'absolute', left: 120, top: 838, display: 'flex', gap: 40}}>
        {fact(PAINT1 + 0.3, `${car.strokes}`, 'axe draw strokes')}
        {fact(PAINT1 + 0.5, '5', 'PencilKit tools')}
        {fact(PAINT1 + 0.7, '1', 'command line')}
      </div>
      <svg width={1920} height={1080} style={{position: 'absolute', inset: 0, opacity: tw(t, 0.9, 1.6)}}>
        <defs>
          <linearGradient id="cable" x1="0" x2="1">
            <stop offset="0" stopColor="rgba(34,211,238,0.0)" />
            <stop offset="0.4" stopColor="rgba(148,163,184,0.5)" />
            <stop offset="1" stopColor="rgba(226,232,240,0.9)" />
          </linearGradient>
        </defs>
        <path id="cablePath" d="M 1130 700 C 1270 700, 1260 1040, 1420 1045 S 1525 1040 1525 1010" stroke="url(#cable)" strokeWidth={7} fill="none" strokeLinecap="round" />
        <circle r={7} fill={C.cyanLight} style={{filter: `drop-shadow(0 0 10px ${C.cyan})`}}>
          <animateMotion dur="1s" repeatCount="1" keyPoints={`${1 - pulse};${1 - pulse}`} keyTimes="0;1" calcMode="linear">
            <mpath href="#cablePath" />
          </animateMotion>
        </circle>
      </svg>
      <div style={{position: 'absolute', left: 1300, top: 62 + float}}>
        <Fade at={0.4} y={60} dur={1.1}>
          <Phone
            height={ph}
            aspect={440 / 956}
            rotateY={-12}
            rotateX={3}
            // Hides the status bar's "back to previous app" breadcrumb, the one personal detail on screen.
            overlay={<div style={{position: 'absolute', left: 0, top: '3.7%', width: '26%', height: '2.2%', background: '#fff'}} />}
          >
            <VideoAt src={car.file} time={src} rate={60} style={{width: '100%', height: '100%', objectFit: 'cover'}} />
          </Phone>
        </Fade>
      </div>
      <Fade at={PAINT0} y={0} style={{position: 'absolute', left: 630, top: 358, width: 500, textAlign: 'right'}}>
        <div style={{fontFamily: MONO, fontSize: 19, color: C.cyan, letterSpacing: '0.12em', whiteSpace: 'nowrap'}}>
          {t < PAINT1 ? `● TIME-LAPSE · ${speed}× SPEED` : `${Math.round(car.b - car.a)} S OF REAL INPUT`}
        </div>
      </Fade>
      <Footnote at={2.0} style={{bottom: 28, right: 760}}>
        Screen recording of an iPhone 16 Pro Max painted by AXe, from the end-to-end suite. Device body illustrated.
      </Footnote>
    </Scene>
  );
};

// ───────────────────────────── Everything else ─────────────────────────────
// One dense, pausable board of the rest of the release, in the style of a keynote feature slide.
// Every tile is taken from CHANGELOG.md's v2.0.0 section.
type Tile = {c: string; r: string; big?: string; mono?: string; title?: string; sub?: string; tone?: 'grad' | 'cyan' | 'plain'; code?: string[]; ms?: number; bs?: number};
const TILES: Tile[] = [
  {c: '1 / 5', r: '1 / 3', mono: '--output json', sub: 'One typed JSON result for every command', code: ['{"command":"tap","didError":true,', ' "error":{"code":"elementNotFound",…}}'], tone: 'cyan'},
  {c: '5 / 7', r: '1 / 3', big: '1,000', title: 'points in one stroke', mono: 'axe draw', tone: 'grad'},
  {c: '7 / 10', r: '1 / 2', title: 'Typed error codes', sub: 'One set for simulators and devices'},
  {c: '10 / 13', r: '1 / 2', mono: 'axe settings', sub: 'Appearance, text size, VoiceOver, location, status bar', tone: 'cyan'},
  {c: '7 / 9', r: '2 / 3', big: 'H.264', title: 'device streaming', tone: 'grad'},
  {c: '9 / 13', r: '2 / 3', mono: '--until-label  --until-id', sub: 'Scroll until an element is on screen', tone: 'cyan'},
  {c: '1 / 4', r: '3 / 5', big: 'Multi-touch', bs: 66, sub: 'Pinch, rotate, two-finger tap, hold and swipe', mono: 'axe gesture pinch --scale 2', tone: 'grad'},
  {c: '4 / 7', r: '3 / 4', title: 'Long press, double tap', mono: '--hold  --count 2  --touches 2'},
  {c: '4 / 7', r: '4 / 5', mono: 'batch --agent', sub: 'Fill a whole form in one call', tone: 'cyan'},
  {c: '7 / 10', r: '3 / 5', big: 'doctor', sub: 'Pairing, Developer Mode, disk image and lock state, checked before you start', mono: 'axe doctor --udid $DEVICE', tone: 'grad'},
  {c: '10 / 13', r: '3 / 4', mono: 'drag --hold', sub: 'Rest, then move: reorder a list', tone: 'cyan'},
  {c: '10 / 13', r: '4 / 5', title: 'Control Centre', mono: 'swipe-from-top-right-corner'},
  {c: '1 / 3', r: '5 / 7', big: 'Schemas', bs: 50, sub: 'JSON Schema files for every result', mono: 'schemas/', tone: 'grad'},
  {c: '3 / 7', r: '5 / 6', mono: 'record-video --follow-active-display', ms: 23, sub: 'One movie through folds and rotations', tone: 'cyan'},
  {c: '3 / 7', r: '6 / 7', mono: 'axe agent "<goal>"', sub: 'Experimental: reach a plain-language goal, one checked action at a time', tone: 'cyan'},
  {c: '7 / 10', r: '5 / 6', mono: 'displays · hinge · rotate', ms: 24, sub: 'Screens, fold angle and orientation', tone: 'cyan'},
  {c: '10 / 13', r: '5 / 6', mono: 'clipboard · shutdown', sub: 'Simulator clipboard and clean shutdown', tone: 'cyan'},
  {c: '7 / 10', r: '6 / 7', title: 'Plugin marketplaces', sub: 'Claude Code and Codex: the AXe skill updates with each release'},
  {c: '10 / 13', r: '6 / 7', title: 'Every --help rewritten', sub: 'Examples and one-line options'},
];
export const BENTO = 9.0;
export const Bento: React.FC = () => {
  const t = useT();
  return (
    <Scene dur={BENTO}>
      <div style={{position: 'absolute', left: 70, top: 44, right: 70, display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', opacity: tw(t, 0, 0.5)}}>
        <div style={{fontFamily: FONT, fontWeight: 600, fontSize: 44, letterSpacing: '-0.03em', color: C.text}}>
          And there’s more in <span style={{backgroundImage: GRAD, WebkitBackgroundClip: 'text', backgroundClip: 'text', color: 'transparent'}}>AXe 2.0</span>
        </div>
        <div style={{fontFamily: MONO, fontSize: 20, color: C.muted, letterSpacing: '0.16em'}}>FULL CHANGELOG · AXE-CLI.COM</div>
      </div>
      <div style={{position: 'absolute', left: 70, right: 70, top: 124, bottom: 46, display: 'grid', gridTemplateColumns: 'repeat(12, 1fr)', gridTemplateRows: 'repeat(6, 1fr)', gap: 16}}>
        {TILES.map((tile, i) => {
          // Tiles arrive in a diagonal sweep from the top left.
          const col = parseInt(tile.c, 10), row = parseInt(tile.r, 10);
          const at = 0.25 + (col + row * 2) * 0.045;
          const p = tw(t, at, at + 0.7);
          const tall = tile.r === '1 / 3' || tile.r === '3 / 5' || tile.r === '5 / 7';
          const hero = tile.tone === 'grad';
          return (
            <div
              key={i}
              style={{
                gridColumn: tile.c,
                gridRow: tile.r,
                borderRadius: 26,
                padding: tall ? '26px 30px' : '18px 26px',
                background: hero
                  ? 'linear-gradient(150deg, rgba(34,211,238,0.16), rgba(59,130,246,0.10) 45%, rgba(124,58,237,0.14))'
                  : 'linear-gradient(160deg, rgba(23,29,42,0.92), rgba(12,16,23,0.82))',
                border: `1px solid ${hero ? 'rgba(103,232,249,0.28)' : C.line}`,
                boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.06)',
                opacity: p,
                transform: `scale(${0.9 + p * 0.1}) translateY(${(1 - p) * 20}px)`,
                display: 'flex',
                flexDirection: 'column',
                justifyContent: tall ? 'space-between' : 'center',
                overflow: 'hidden',
                minWidth: 0,
              }}
            >
              <div>
                {tile.big && (
                  <div style={{fontFamily: FONT, fontWeight: 600, fontSize: tile.bs ?? (tall ? 76 : 54), letterSpacing: '-0.04em', lineHeight: 1, whiteSpace: 'nowrap', backgroundImage: GRAD, WebkitBackgroundClip: 'text', backgroundClip: 'text', color: 'transparent', paddingBottom: 6}}>
                    {tile.big}
                  </div>
                )}
                {!tile.big && !tile.title && tile.mono && (
                  <div style={{fontFamily: MONO, fontSize: tile.ms ?? (tall ? 40 : 27), color: C.cyanLight, whiteSpace: 'nowrap'}}>{tile.mono}</div>
                )}
                {tile.title && <div style={{fontFamily: FONT, fontWeight: 600, fontSize: tile.big ? 26 : 31, color: C.text, letterSpacing: '-0.01em', marginTop: tile.big ? 2 : 0}}>{tile.title}</div>}
                {tile.sub && <div style={{fontFamily: FONT, fontSize: 22, color: C.sub, marginTop: 6, lineHeight: 1.25}}>{tile.sub}</div>}
              </div>
              {tile.code && (
                <div style={{fontFamily: MONO, fontSize: 19, color: '#B6C2D6', background: 'rgba(5,7,12,0.6)', borderRadius: 14, padding: '14px 16px', whiteSpace: 'pre', lineHeight: 1.5}}>
                  {tile.code.join('\n')}
                </div>
              )}
              {(tile.big || tile.title) && tile.mono && (
                <div style={{fontFamily: MONO, fontSize: 20, color: hero ? C.cyanLight : C.sub, marginTop: 8, whiteSpace: 'nowrap'}}>
                  {tile.mono}
                </div>
              )}
            </div>
          );
        })}
      </div>
    </Scene>
  );
};

// ───────────────────────────── Outro ─────────────────────────────
export const OUTRO = 6.4;
export const Outro: React.FC = () => {
  const t = useT();
  const glow = 0.5 + 0.5 * Math.sin(t * 2.2);
  const cmd = 'brew install cameroncooke/axe/axe';
  const n = Math.round(tw(t, 1.9, 2.8, 0, cmd.length, (x) => x));
  return (
    <AbsoluteFill style={{opacity: Math.min(tw(t, 0, 0.5, 0, 1, Easing.out(Easing.quad)), tw(t, OUTRO - 0.9, OUTRO - 0.1, 1, 0, Easing.in(Easing.quad)))}}>
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
        <div style={{display: 'flex', alignItems: 'center', gap: 44, transform: 'translateY(-120px)'}}>
          <Img
            src={staticFile('icon.png')}
            style={{width: 190, height: 190, opacity: tw(t, 0.1, 1.0), transform: `scale(${tw(t, 0.1, 1.2, 0.8, 1)})`, filter: `drop-shadow(0 0 ${26 + glow * 26}px rgba(34,211,238,0.45))`}}
          />
          <Lockup h={130} word={{opacity: tw(t, 0.3, 1.2)}} two={{opacity: tw(t, 0.5, 1.4)}} />
        </div>
        <div style={{position: 'absolute', top: 560, width: '100%', display: 'flex', justifyContent: 'center'}}>
          <Rise text="Simulators. The iPhone Duo. Real devices." at={0.9} style={{...SUB, fontSize: 46, color: C.text, justifyContent: 'center'}} />
        </div>
        <div style={{position: 'absolute', top: 690, width: '100%', display: 'flex', justifyContent: 'center', opacity: tw(t, 1.7, 2.2)}}>
          <div style={{fontFamily: MONO, fontSize: 36, color: C.text, padding: '24px 40px', borderRadius: 20, background: 'rgba(12,16,23,0.85)', border: '1px solid rgba(34,211,238,0.35)', boxShadow: '0 0 50px rgba(34,211,238,0.12)', whiteSpace: 'pre'}}>
            <span style={{color: C.cyan}}>❯ </span>
            {cmd.slice(0, n)}
            <span style={{opacity: 0}}>{cmd.slice(n)}</span>
          </div>
        </div>
        <Fade at={3.0} style={{position: 'absolute', top: 850, width: '100%', textAlign: 'center'}}>
          <div style={{fontFamily: FONT, fontSize: 34, color: C.sub, letterSpacing: '0.02em'}}>axe-cli.com</div>
        </Fade>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
