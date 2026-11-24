import React from 'react';
import {AbsoluteFill, Audio, Composition, Sequence, staticFile} from 'remotion';
import {Backdrop, FPS, H, W} from './lib';
import {FILM21} from './film21';
import {TOUR} from './tour';
import {Versionless} from './edition';
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

// The AXe 2.1 film: same frame, same backdrop, its own scenes and music.
export const TOTAL21 = FILM21.reduce((a, s) => a + s[1], 0);
const Film21: React.FC<{music: boolean}> = ({music}) => {
  let at = 0;
  return (
    <AbsoluteFill>
      <Backdrop />
      {FILM21.map(([name, dur, Comp]) => {
        const from = at;
        at += dur;
        return (
          <Sequence key={name} name={name} from={f(from)} durationInFrames={f(dur)}>
            <Comp />
          </Sequence>
        );
      })}
      {music && <Audio src={staticFile('v21/music.wav')} />}
    </AbsoluteFill>
  );
};

// The tour for the website: AXe as it is now, with no version numbers in it.
export const TOTAL_TOUR = TOUR.reduce((a, s) => a + s[1], 0);
const Tour: React.FC<{music: boolean}> = ({music}) => {
  let at = 0;
  return (
    <Versionless.Provider value={true}>
      <AbsoluteFill>
        <Backdrop />
        {TOUR.map(([name, dur, Comp]) => {
          const from = at;
          at += dur;
          return (
            <Sequence key={name} name={name} from={f(from)} durationInFrames={f(dur)}>
              <Comp />
            </Sequence>
          );
        })}
        {music && <Audio src={staticFile('tour/music.wav')} />}
      </AbsoluteFill>
    </Versionless.Provider>
  );
};

export const Root: React.FC = () => (
  <>
    <Composition id="Promo" component={Promo} durationInFrames={f(TOTAL)} fps={FPS} width={W} height={H} defaultProps={{music: true}} />
    <Composition id="Tour" component={Tour} durationInFrames={f(TOTAL_TOUR)} fps={FPS} width={W} height={H} defaultProps={{music: true}} />
    <Composition id="Film21" component={Film21} durationInFrames={f(TOTAL21)} fps={FPS} width={W} height={H} defaultProps={{music: true}} />
  </>
);
