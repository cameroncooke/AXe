import React from 'react';
import {AbsoluteFill, Audio, Composition, Sequence, staticFile} from 'remotion';
import {Backdrop, FPS, H, W} from './lib';
import {AGENT, Agent, BENCH, Bench, BENTO, Bento, DEVICE, Device, DUO, DuoScene, INTRO, Intro, OUTRO, Outro, SPEED, Speed, WHATSNEW, WhatsNew} from './scenes';

// Scene order and lengths in seconds. Each scene fades itself in and out.
const SCENES: [string, number, React.FC][] = [
  ['Intro', INTRO, Intro],
  ['WhatsNew', WHATSNEW, WhatsNew],
  ['Speed', SPEED, Speed],
  ['Agent', AGENT, Agent],
  ['Benchmark', BENCH, Bench],
  ['Duo', DUO, DuoScene],
  ['Device', DEVICE, Device],
  ['Everything else', BENTO, Bento],
  ['Outro', OUTRO, Outro],
];
export const TOTAL = SCENES.reduce((a, s) => a + s[1], 0);
const f = (s: number) => Math.round(s * FPS);

const Promo: React.FC<{music: boolean}> = ({music}) => {
  let at = 0;
  return (
    <AbsoluteFill>
      <Backdrop />
      {SCENES.map(([name, dur, Comp]) => {
        const from = at;
        at += dur;
        return (
          <Sequence key={name} name={name} from={f(from)} durationInFrames={f(dur)}>
            <Comp />
          </Sequence>
        );
      })}
      {music && <Audio src={staticFile('music.wav')} />}
    </AbsoluteFill>
  );
};

export const Root: React.FC = () => (
  <Composition id="Promo" component={Promo} durationInFrames={f(TOTAL)} fps={FPS} width={W} height={H} defaultProps={{music: true}} />
);
