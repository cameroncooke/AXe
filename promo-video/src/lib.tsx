import React from 'react';
import {
  AbsoluteFill,
  Easing,
  Freeze,
  interpolate,
  OffthreadVideo,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import {loadFont as loadRubik} from '@remotion/google-fonts/Rubik';
import {loadFont as loadMono} from '@remotion/google-fonts/RobotoMono';

const rubik = loadRubik('normal', {weights: ['300', '400', '500', '600', '700'], subsets: ['latin']});
const mono = loadMono('normal', {weights: ['400', '500'], subsets: ['latin']});

export const FPS = 60;
export const W = 1920;
export const H = 1080;

export const C = {
  bg: '#05070C',
  panel: '#0C1017',
  panel2: '#111620',
  line: 'rgba(148,163,184,0.14)',
  cyan: '#22D3EE',
  cyanLight: '#67E8F9',
  blue: '#3B82F6',
  purple: '#7C3AED',
  text: '#F1F5F9',
  sub: '#8B9AB5',
  muted: '#5B6B84',
  green: '#34D399',
};
export const FONT = rubik.fontFamily;
export const MONO = mono.fontFamily;
export const GRAD = `linear-gradient(100deg, ${C.cyanLight} 0%, ${C.cyan} 30%, ${C.blue} 70%, ${C.purple} 100%)`;

export const outExpo = Easing.bezier(0.16, 1, 0.3, 1);
export const inOut = Easing.bezier(0.65, 0, 0.35, 1);

/** Seconds since the start of the enclosing Sequence. */
export const useT = () => {
  const f = useCurrentFrame();
  const {fps} = useVideoConfig();
  return f / fps;
};

export const tw = (t: number, a: number, b: number, from = 0, to = 1, easing: (n: number) => number = outExpo) =>
  interpolate(t, [a, b], [from, to], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing});

/** Scene wrapper: fades and settles in, fades out at the end. */
export const Scene: React.FC<{dur: number; children: React.ReactNode}> = ({dur, children}) => {
  const t = useT();
  const o = Math.min(tw(t, 0, 0.5, 0, 1, Easing.out(Easing.quad)), tw(t, dur - 0.45, dur, 1, 0, Easing.in(Easing.quad)));
  const s = tw(t, dur - 0.45, dur, 1, 1.03, Easing.in(Easing.quad));
  return <AbsoluteFill style={{opacity: o, transform: `scale(${s})`}}>{children}</AbsoluteFill>;
};

/** Text that rises in word by word. */
export const Rise: React.FC<{
  text: string;
  at: number;
  style?: React.CSSProperties;
  stagger?: number;
  gradientWords?: string[];
}> = ({text, at, style, stagger = 0.07, gradientWords = []}) => {
  const t = useT();
  const words = text.split(' ');
  return (
    <div style={{display: 'flex', flexWrap: 'wrap', columnGap: '0.26em', ...style}}>
      {words.map((w, i) => {
        const p = tw(t, at + i * stagger, at + i * stagger + 0.8);
        const grad = gradientWords.includes(w);
        return (
          <span
            key={i}
            style={{
              display: 'inline-block',
              opacity: p,
              transform: `translateY(${(1 - p) * 0.5}em)`,
              filter: `blur(${(1 - p) * 10}px)`,
              ...(grad
                ? {backgroundImage: GRAD, WebkitBackgroundClip: 'text', backgroundClip: 'text', color: 'transparent'}
                : {}),
            }}
          >
            {w}
          </span>
        );
      })}
    </div>
  );
};

export const Fade: React.FC<{at: number; dur?: number; y?: number; children: React.ReactNode; style?: React.CSSProperties}> = ({
  at,
  dur = 0.7,
  y = 18,
  children,
  style,
}) => {
  const t = useT();
  const p = tw(t, at, at + dur);
  return <div style={{opacity: p, transform: `translateY(${(1 - p) * y}px)`, ...style}}>{children}</div>;
};

export const Eyebrow: React.FC<{at: number; children: React.ReactNode}> = ({at, children}) => (
  <Fade at={at}>
    <div
      style={{
        fontFamily: MONO,
        fontSize: 22,
        letterSpacing: '0.22em',
        textTransform: 'uppercase',
        color: C.cyan,
        marginBottom: 22,
      }}
    >
      {children}
    </div>
  </Fade>
);

export const Footnote: React.FC<{at: number; children: React.ReactNode; style?: React.CSSProperties}> = ({at, children, style}) => (
  <Fade at={at} y={0} style={{position: 'absolute', left: 120, bottom: 54, right: 120, ...style}}>
    <div style={{fontFamily: FONT, fontSize: 19, color: C.muted, lineHeight: 1.45}}>{children}</div>
  </Fade>
);

/** Global backdrop: deep navy, drifting glows, a faint blueprint grid. */
export const Backdrop: React.FC = () => {
  const f = useCurrentFrame();
  const t = f / FPS;
  const x1 = 30 + Math.sin(t * 0.21) * 12;
  const y1 = 28 + Math.cos(t * 0.17) * 10;
  const x2 = 72 + Math.cos(t * 0.13) * 12;
  const y2 = 74 + Math.sin(t * 0.19) * 10;
  return (
    <AbsoluteFill style={{background: C.bg}}>
      <AbsoluteFill
        style={{
          background: `radial-gradient(900px 700px at ${x1}% ${y1}%, rgba(34,211,238,0.13), transparent 70%), radial-gradient(1000px 800px at ${x2}% ${y2}%, rgba(59,130,246,0.14), transparent 70%), radial-gradient(700px 600px at 50% 110%, rgba(124,58,237,0.12), transparent 70%)`,
        }}
      />
      <AbsoluteFill
        style={{
          backgroundImage:
            'linear-gradient(rgba(103,232,249,0.05) 1px, transparent 1px), linear-gradient(90deg, rgba(103,232,249,0.05) 1px, transparent 1px)',
          backgroundSize: '80px 80px',
          backgroundPosition: `${-t * 6}px ${-t * 4}px`,
          maskImage: 'radial-gradient(ellipse at 50% 50%, black 0%, transparent 72%)',
          WebkitMaskImage: 'radial-gradient(ellipse at 50% 50%, black 0%, transparent 72%)',
        }}
      />
      <AbsoluteFill style={{background: 'radial-gradient(ellipse at 50% 50%, transparent 55%, rgba(0,0,0,0.55) 100%)'}} />
    </AbsoluteFill>
  );
};

/**
 * Shows a video at an arbitrary source time, so footage can be frozen and retimed.
 * `rate` keeps the frozen frame number small for long sources: Remotion does not seek a video
 * past the composition's own length, so a time-lapse reaches late footage through playbackRate.
 */
export const VideoAt: React.FC<{src: string; time: number; rate?: number; style?: React.CSSProperties}> = ({src, time, rate = 1, style}) => {
  const {fps} = useVideoConfig();
  return (
    <Freeze frame={Math.max(0, Math.round((time * fps) / rate))}>
      <OffthreadVideo src={staticFile(src)} muted playbackRate={rate} style={style} />
    </Freeze>
  );
};

export type Line = {at: number; kind: 'cmd' | 'out' | 'ok' | 'dim' | 'gap'; text?: string; typeDur?: number};

/** A terminal window whose commands type themselves and whose output appears line by line. */
export const Terminal: React.FC<{
  lines: Line[];
  width: number;
  height: number;
  title?: string;
  fontSize?: number;
  style?: React.CSSProperties;
}> = ({lines, width, height, title = 'zsh', fontSize = 22, style}) => {
  const t = useT();
  const lh = fontSize * 1.62;
  const visible = lines.filter((l) => t >= l.at);
  const bodyH = height - 52 - 44;
  const overflow = Math.max(0, visible.length * lh - bodyH);
  // Ease the scroll rather than jumping a line at a time.
  const lastAt = visible.length ? visible[visible.length - 1].at : 0;
  const prevOverflow = Math.max(0, (visible.length - 1) * lh - bodyH);
  const scroll = prevOverflow + (overflow - prevOverflow) * tw(t, lastAt, lastAt + 0.25);
  return (
    <div
      style={{
        width,
        height,
        borderRadius: 22,
        background: 'linear-gradient(180deg, rgba(17,22,32,0.92), rgba(9,12,18,0.94))',
        border: `1px solid ${C.line}`,
        boxShadow: '0 40px 120px rgba(0,0,0,0.55), 0 0 60px rgba(34,211,238,0.07), inset 0 1px 0 rgba(255,255,255,0.05)',
        overflow: 'hidden',
        ...style,
      }}
    >
      <div style={{height: 52, display: 'flex', alignItems: 'center', padding: '0 20px', gap: 9, borderBottom: `1px solid ${C.line}`}}>
        {['#FF5F57', '#FEBC2E', '#28C840'].map((c) => (
          <div key={c} style={{width: 13, height: 13, borderRadius: 7, background: c, opacity: 0.85}} />
        ))}
        <div style={{flex: 1, textAlign: 'center', fontFamily: MONO, fontSize: 16, color: C.muted, marginRight: 57}}>{title}</div>
      </div>
      <div style={{height: bodyH, margin: '22px 26px', overflow: 'hidden', position: 'relative'}}>
        <div style={{transform: `translateY(${-scroll}px)`, fontFamily: MONO, fontSize, lineHeight: `${lh}px`, whiteSpace: 'pre'}}>
          {visible.map((l, i) => {
            if (l.kind === 'gap') return <div key={i} style={{height: lh * 0.45}} />;
            if (l.kind === 'cmd') {
              const d = l.typeDur ?? Math.min(0.7, (l.text ?? '').length * 0.018);
              const n = Math.round(tw(t, l.at, l.at + d, 0, (l.text ?? '').length, (x) => x));
              const typing = n < (l.text ?? '').length;
              const last = i === visible.length - 1;
              return (
                <div key={i} style={{color: C.text}}>
                  <span style={{color: C.cyan}}>❯ </span>
                  {(l.text ?? '').slice(0, n)}
                  {(typing || last) && (
                    <span style={{background: C.cyan, opacity: typing || Math.floor(t * 2.5) % 2 === 0 ? 0.9 : 0, color: 'transparent'}}>▌</span>
                  )}
                </div>
              );
            }
            const o = tw(t, l.at, l.at + 0.25);
            const color = l.kind === 'ok' ? C.green : l.kind === 'dim' ? C.muted : '#B6C2D6';
            return (
              <div key={i} style={{color, opacity: o}}>
                {l.text}
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
};

/** A tap ripple at a point, in the parent's coordinate space. */
export const Ripple: React.FC<{at: number; x: number; y: number; size?: number}> = ({at, x, y, size = 90}) => {
  const t = useT();
  if (t < at - 0.05 || t > at + 0.9) return null;
  const p = tw(t, at, at + 0.7);
  return (
    <>
      <div
        style={{
          position: 'absolute',
          left: x - size / 2,
          top: y - size / 2,
          width: size,
          height: size,
          borderRadius: size,
          border: `3px solid ${C.cyanLight}`,
          opacity: (1 - p) * 0.9,
          transform: `scale(${0.3 + p * 1.1})`,
          boxShadow: `0 0 30px ${C.cyan}`,
        }}
      />
      <div
        style={{
          position: 'absolute',
          left: x - 14,
          top: y - 14,
          width: 28,
          height: 28,
          borderRadius: 14,
          background: 'rgba(103,232,249,0.85)',
          opacity: tw(t, at, at + 0.45, 1, 0),
        }}
      />
    </>
  );
};

/** A command pill that slides in, used beside the hardware. */
export const Chip: React.FC<{text: string; from: number; to: number; note?: string}> = ({text, from, to, note}) => {
  const t = useT();
  if (t < from - 0.05 || t > to + 0.4) return null;
  const o = Math.min(tw(t, from, from + 0.45), tw(t, to, to + 0.35, 1, 0));
  const y = tw(t, from, from + 0.5, 22, 0) + tw(t, to, to + 0.35, 0, -18, Easing.in(Easing.quad));
  const n = Math.round(tw(t, from + 0.1, from + 0.1 + Math.min(0.5, text.length * 0.016), 0, text.length, (x) => x));
  return (
    <div style={{position: 'absolute', left: 0, top: 0, opacity: o, transform: `translateY(${y}px)`}}>
      <div
        style={{
          display: 'inline-block',
          fontFamily: MONO,
          fontSize: 30,
          color: C.text,
          padding: '20px 28px',
          borderRadius: 18,
          background: 'rgba(12,16,23,0.85)',
          border: `1px solid rgba(34,211,238,0.35)`,
          boxShadow: '0 20px 60px rgba(0,0,0,0.5), 0 0 40px rgba(34,211,238,0.12)',
          whiteSpace: 'pre',
        }}
      >
        <span style={{color: C.cyan}}>❯ </span>
        {text.slice(0, n)}
      </div>
      {note && (
        <div style={{fontFamily: MONO, fontSize: 22, color: C.sub, marginTop: 16, marginLeft: 6, opacity: tw(t, from + 0.7, from + 1.0), whiteSpace: 'pre'}}>
          {note}
        </div>
      )}
    </div>
  );
};
