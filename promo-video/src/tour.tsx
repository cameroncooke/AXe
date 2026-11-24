import React from 'react';
import {C, Chip, Eyebrow, Fade, FONT, Footnote, Line, MONO, Rise, Scene, Terminal, tw, useT, VideoAt} from './lib';
import {Duo, Phone} from './hardware';
import {AGENT, Agent, BENCH, Bench, BENTO, Bento, DEVICE, Device, DUO, DuoScene, INTRO, Intro, OUTRO, Outro, SPEED, Speed} from './scenes';

// The tour: AXe as it is now, for the website's homepage. It reuses the 2.0 film's scenes in their
// versionless form (see edition.ts) and adds a scene for web pages in agent mode and one for
// AXe Mirror, both from the real session recorded for the Mirror film (public/v21).

const H1: React.CSSProperties = {fontFamily: FONT, fontWeight: 600, fontSize: 104, lineHeight: 1.02, letterSpacing: '-0.035em', color: C.text};
const SUB: React.CSSProperties = {fontFamily: FONT, fontWeight: 400, fontSize: 34, lineHeight: 1.35, color: C.sub, letterSpacing: '-0.01em'};

// ───────────────────────────── Web pages ─────────────────────────────
// The simulator's picture as the iPhone Duo showed it (duo.mp4; the Mac's own recording skips the
// empty page, because the Simulator records only when the screen changes). The empty sign-in page is
// on screen until 59.6 s and is held while the agent reads it; the email is typed by 61.5 s, the
// password by 69 s, and the app is back on the trip at 75.6 s.
export const WEB = 9.0;
const WEB_HOLD = 57.0;
const WEB_SRC0 = 59.6;
const WEB_RATE = 2.8;
const WEB_T0 = 2.0;
const webSrc = (t: number) => (t < WEB_T0 ? WEB_HOLD : Math.min(76.2, WEB_SRC0 + WEB_RATE * (t - WEB_T0)));
/** The mirrored simulator's place in the Duo recording, as fractions of its frame. */
const SIM = {x: 0.5662, w: 0.3067, h: 0.95};
const webAt = (src: number) => WEB_T0 + (src - WEB_SRC0) / WEB_RATE;
const WEB_LINES: Line[] = [
  {at: 0.6, kind: 'cmd', text: 'axe describe-ui --agent --web', typeDur: 0.35},
  {at: 1.05, kind: 'out', text: 'w3|typeText|text-field|Email|'},
  {at: 1.12, kind: 'out', text: 'w4|typeText|text-field|Password|'},
  {at: 1.19, kind: 'out', text: 'w5|tap|button|Sign in|'},
  {at: 1.75, kind: 'gap'},
  {at: 1.75, kind: 'cmd', text: "axe type --agent --focus --ref w3 'ada@example.com'", typeDur: 0.35},
  {at: webAt(61.6), kind: 'ok', text: '✓ typed · new snapshot'},
  {at: webAt(61.6) + 0.05, kind: 'out', text: 'w2|typeText|text-field|Password|'},
  {at: webAt(66.5), kind: 'gap'},
  {at: webAt(66.5), kind: 'cmd', text: "axe type --agent --focus --ref w2 '•••••'", typeDur: 0.3},
  {at: webAt(69.2), kind: 'ok', text: '✓ typed · new snapshot'},
  {at: webAt(69.2) + 0.05, kind: 'out', text: 'w3|tap|button|Sign in|'},
  {at: webAt(72.8), kind: 'gap'},
  {at: webAt(72.8), kind: 'cmd', text: 'axe tap --agent --ref w3', typeDur: 0.25},
  {at: webAt(75.7), kind: 'ok', text: '✓ signed in · back in the app'},
];
/** Boxes over the page's three controls, as fractions of the simulator's screen. */
const WebTags: React.FC<{t: number}> = ({t}) => {
  const o = Math.min(tw(t, 1.05, 1.35), tw(t, WEB_T0, WEB_T0 + 0.25, 1, 0));
  if (o <= 0) return null;
  const tag = (y0: number, y1: number, label: string) => (
    <div key={label} style={{position: 'absolute', left: '5%', width: '90%', top: `${y0 * 100}%`, height: `${(y1 - y0) * 100}%`, borderRadius: 10, border: `3px solid ${C.cyan}`, boxShadow: '0 0 20px rgba(34,211,238,0.6)'}}>
      <div style={{position: 'absolute', right: 6, top: '50%', transform: 'translateY(-50%)', padding: '2px 9px', borderRadius: 7, background: C.cyan, color: '#04121a', fontFamily: MONO, fontWeight: 500, fontSize: 18}}>{label}</div>
    </div>
  );
  return <div style={{position: 'absolute', inset: 0, opacity: o}}>{[tag(0.342, 0.397, 'w3'), tag(0.442, 0.496, 'w4'), tag(0.523, 0.577, 'w5')]}</div>;
};
export const Web: React.FC = () => {
  const t = useT();
  const float = Math.sin(t * 0.9) * 6;
  return (
    <Scene dur={WEB}>
      <div style={{position: 'absolute', left: 120, top: 84, width: 1100}}>
        <Eyebrow at={0.1}>Agent mode</Eyebrow>
        <Rise text="Web pages, too." at={0.2} style={H1} gradientWords={['Web', 'pages,']} />
        <Fade at={0.8} style={{marginTop: 20}}>
          <div style={SUB}>Sign-in sheets, Safari and web views in any app.</div>
        </Fade>
      </div>
      <div style={{position: 'absolute', left: 120, top: 400}}>
        <Fade at={0.5}>
          <Terminal lines={WEB_LINES} width={1020} height={470} title="axe — agent mode" fontSize={21} />
        </Fade>
      </div>
      <div style={{position: 'absolute', left: 1330, top: 70 + float}}>
        <Fade at={0.4} y={60} dur={1.0}>
          <Phone height={940} rotateY={-13} rotateX={3} overlay={<WebTags t={t} />}>
            <div style={{position: 'absolute', inset: 0, overflow: 'hidden'}}>
              <div style={{position: 'absolute', left: `${(-SIM.x / SIM.w) * 100}%`, top: 0, width: `${100 / SIM.w}%`, height: `${100 / SIM.h}%`}}>
                <VideoAt src="v21/duo.mp4" time={webSrc(t)} rate={3} style={{width: '100%', height: '100%', objectFit: 'fill'}} />
              </div>
            </div>
          </Phone>
        </Fade>
      </div>
      <Footnote at={1.4} style={{left: 1220, right: 60, bottom: 30, textAlign: 'right'}}>
        A real session. Screen recording at {WEB_RATE}× speed.
      </Footnote>
    </Scene>
  );
};

// ───────────────────────────── AXe Mirror ─────────────────────────────
// duo.mp4 is the iPhone Duo's own screen recording. From 93 s its owner swipes, pinches and taps the
// mirrored simulator while the agent waits on the other side.
export const MIRROR = 13.0;
const MIR_SRC0 = 93.0;
const MIR_RATE = 1.8;
const MIR_T0 = 1.2;
export const Mirror: React.FC = () => {
  const t = useT();
  const src = t < MIR_T0 ? MIR_SRC0 : Math.min(112.6, MIR_SRC0 + MIR_RATE * (t - MIR_T0));
  const screenH = 560;
  const innerW = (screenH * 951) / 669;
  const rotY = -14 + Math.sin(t * 0.5) * 3;
  return (
    <Scene dur={MIRROR}>
      <div style={{position: 'absolute', left: 120, top: 96, width: 860}}>
        <Eyebrow at={0.1}>AXe Mirror</Eyebrow>
        <Rise text="Your simulator." at={0.2} style={H1} />
        <Rise text="In your hand." at={0.5} style={H1} gradientWords={['your', 'hand.']} />
        <Fade at={1.0} style={{marginTop: 26}}>
          <div style={SUB}>See and touch your agent's simulator from an iPhone or iPad, from anywhere. Encrypted from end to end.</div>
        </Fade>
      </div>
      <div style={{position: 'absolute', left: 120, top: 700, width: 800, height: 150}}>
        <Chip text="axe mirror pair" from={1.4} to={4.4} note="once, with a code or a QR code" />
        <Chip text='axe mirror --udid "$UDID"' from={4.6} to={MIRROR - 0.6} note="the free AXe Mirror app shows it, live" />
      </div>
      <div style={{position: 'absolute', left: 1385 - (innerW + 40) / 2, top: 540 - 310}}>
        <Fade at={0.3} y={50} dur={1.1}>
          <Duo
            screenH={screenH}
            angle={180}
            rotateX={6}
            rotateY={rotY}
            glare={false}
            outer={<div />}
            inner={<VideoAt src="v21/duo.mp4" time={src} rate={3} style={{width: '100%', height: '100%', objectFit: 'cover'}} />}
          />
        </Fade>
      </div>
      <Footnote at={1.8} style={{left: 1000, right: 80, textAlign: 'right'}}>
        Screen recording from an iPhone Duo, at {MIR_RATE}× speed. Device body illustrated.
      </Footnote>
    </Scene>
  );
};

export const TOUR: [string, number, React.FC][] = [
  ['Intro', INTRO, Intro],
  ['Speed', SPEED, Speed],
  ['Agent', AGENT, Agent],
  ['Web pages', WEB, Web],
  ['Benchmark', BENCH, Bench],
  ['Duo', DUO, DuoScene],
  ['Device', DEVICE, Device],
  ['Mirror', MIRROR, Mirror],
  ['Everything else', BENTO, Bento],
  ['Outro', OUTRO, Outro],
];
