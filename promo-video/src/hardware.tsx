import React from 'react';

const METAL = 'linear-gradient(135deg, #5d6470 0%, #2b3038 22%, #14171c 50%, #30353d 78%, #6a717d 100%)';
const EDGE = '#1a1d23';

const Glare: React.FC<{radius: number | string}> = ({radius}) => (
  <div
    style={{
      position: 'absolute',
      inset: 0,
      borderRadius: radius,
      background: 'linear-gradient(115deg, rgba(255,255,255,0.10) 0%, rgba(255,255,255,0.03) 22%, transparent 40%, transparent 100%)',
      pointerEvents: 'none',
    }}
  />
);

/** Stacked copies of the body silhouette give the slab real thickness in 3D. */
const Extrusion: React.FC<{depth: number; radius: string | number; from?: number}> = ({depth, radius, from = 0}) => (
  <>
    {Array.from({length: Math.ceil(depth / 2)}).map((_, i) => (
      <div
        key={i}
        style={{
          position: 'absolute',
          inset: 0,
          borderRadius: radius,
          background: i % 4 === 0 ? '#3a4049' : EDGE,
          transform: `translateZ(${from - (i + 1) * 2}px)`,
        }}
      />
    ))}
  </>
);

/**
 * An iPhone drawn in CSS: titanium band, black bezel, Dynamic Island, side buttons.
 * `screenW`/`screenH` are the logical screen size the child content is laid out in.
 */
export const Phone: React.FC<{
  height: number;
  aspect?: number; // screen width / height
  island?: boolean;
  rotateY?: number;
  rotateX?: number;
  rotateZ?: number;
  children: React.ReactNode;
  overlay?: React.ReactNode;
}> = ({height, aspect = 402 / 874, island = true, rotateY = 0, rotateX = 0, rotateZ = 0, children, overlay}) => {
  const band = height * 0.0065;
  const bezel = height * 0.0125;
  const sh = height - 2 * (band + bezel);
  const sw = sh * aspect;
  const width = sw + 2 * (band + bezel);
  const rOuter = height * 0.073;
  const rScreen = rOuter - band - bezel;
  const depth = height * 0.03;
  const button = (side: 'left' | 'right', top: number, len: number) => (
    <div
      style={{
        position: 'absolute',
        [side]: -height * 0.004,
        top: height * top,
        width: height * 0.006,
        height: height * len,
        borderRadius: 4,
        background: 'linear-gradient(90deg, #6a717d, #2b3038)',
        transform: `translateZ(${-depth / 2}px)`,
      }}
    />
  );
  return (
    <div style={{perspective: 2600, width, height}}>
      <div
        style={{
          width,
          height,
          position: 'relative',
          transformStyle: 'preserve-3d',
          transform: `rotateX(${rotateX}deg) rotateY(${rotateY}deg) rotateZ(${rotateZ}deg)`,
        }}
      >
        <Extrusion depth={depth} radius={rOuter} />
        {button('left', 0.19, 0.035)}
        {button('left', 0.25, 0.06)}
        {button('left', 0.33, 0.06)}
        {button('right', 0.28, 0.1)}
        <div
          style={{
            position: 'absolute',
            inset: 0,
            borderRadius: rOuter,
            background: METAL,
            boxShadow: 'inset 0 0 2px rgba(255,255,255,0.5)',
          }}
        />
        <div style={{position: 'absolute', inset: band, borderRadius: rOuter - band, background: '#000'}} />
        <div
          style={{
            position: 'absolute',
            left: band + bezel,
            top: band + bezel,
            width: sw,
            height: sh,
            borderRadius: rScreen,
            overflow: 'hidden',
            background: '#000',
          }}
        >
          {children}
          {island && (
            <div
              style={{
                position: 'absolute',
                left: '50%',
                top: sh * 0.0135,
                width: sw * 0.3,
                height: sh * 0.041,
                marginLeft: -sw * 0.15,
                borderRadius: sh * 0.03,
                background: '#000',
              }}
            />
          )}
          {overlay}
          <Glare radius={rScreen} />
        </div>
      </div>
    </div>
  );
};

/**
 * The iPhone Duo: a book-style foldable. `angle` is the hinge angle AXe reports,
 * 0 (closed, cover screen showing) to 180 (open flat, inner screen showing).
 * `inner` is laid out across both halves; `outer` fills the cover screen.
 */
export const Duo: React.FC<{
  screenH: number;
  angle: number;
  rotateX?: number;
  rotateY?: number;
  rotateZ?: number;
  inner: React.ReactNode;
  outer: React.ReactNode;
  innerOverlay?: React.ReactNode;
}> = ({screenH, angle, rotateX = 0, rotateY = 0, rotateZ = 0, inner, outer, innerOverlay}) => {
  const innerW = (screenH * 951) / 669;
  const halfW = innerW / 2;
  const bezel = screenH * 0.02;
  const band = screenH * 0.008;
  const bodyW = halfW + bezel + band;
  const bodyH = screenH + 2 * (bezel + band);
  const depth = screenH * 0.03;
  const backZ = -(Math.ceil(depth / 2) * 2 + 1.5); // just behind the last extrusion layer
  const r = screenH * 0.075;
  const fold = 180 - angle; // rotation of the left half about the hinge
  const closed = fold / 180;
  const rL = `${r}px 0 0 ${r}px`;
  const rR = `0 ${r}px ${r}px 0`;
  const rs = r - bezel - band;
  // Cover screen: 466×678 pt, inset on the back of the left half.
  const coverH = bodyH - 2 * (bezel + band);
  const coverW = Math.min(bodyW - 2 * (bezel + band), (coverH * 466) / 678);
  const shade = Math.sin((Math.min(fold, 180) * Math.PI) / 180);

  const innerLayer = (side: 'left' | 'right') => (
    <div
      style={{
        position: 'absolute',
        top: band + bezel,
        [side === 'left' ? 'right' : 'left']: 0,
        width: halfW,
        height: screenH,
        overflow: 'hidden',
        borderRadius: side === 'left' ? `${rs}px 0 0 ${rs}px` : `0 ${rs}px ${rs}px 0`,
        background: '#000',
        backfaceVisibility: 'hidden',
      }}
    >
      <div style={{position: 'absolute', top: 0, left: side === 'left' ? 0 : -halfW, width: innerW, height: screenH}}>
        {inner}
        {innerOverlay}
      </div>
      {/* The crease and the shading a fold puts on each half. */}
      <div
        style={{
          position: 'absolute',
          inset: 0,
          background:
            side === 'left'
              ? `linear-gradient(90deg, transparent 80%, rgba(0,0,0,${0.10 + shade * 0.35}) 100%)`
              : `linear-gradient(270deg, transparent 80%, rgba(0,0,0,${0.10 + shade * 0.3}) 100%)`,
        }}
      />
      <div style={{position: 'absolute', inset: 0, background: `rgba(0,0,0,${side === 'left' ? shade * 0.28 : shade * 0.08})`}} />
      <Glare radius={0} />
    </div>
  );

  return (
    <div style={{perspective: 2800, width: bodyW * 2, height: bodyH}}>
      <div
        style={{
          position: 'relative',
          width: bodyW * 2,
          height: bodyH,
          transformStyle: 'preserve-3d',
          transform: `translateX(${-closed * bodyW * 0.5}px) rotateX(${rotateX}deg) rotateY(${rotateY}deg) rotateZ(${rotateZ}deg)`,
        }}
      >
        {/* Right half: stays in plane. */}
        <div style={{position: 'absolute', left: bodyW, top: 0, width: bodyW, height: bodyH, transformStyle: 'preserve-3d'}}>
          <Extrusion depth={depth} radius={rR} />
          <div style={{position: 'absolute', inset: 0, borderRadius: rR, background: METAL}} />
          <div style={{position: 'absolute', top: band, bottom: band, left: 0, right: band, borderRadius: `0 ${r - band}px ${r - band}px 0`, background: '#000'}} />
          {innerLayer('right')}
          {/* Back of the right half */}
          <div
            style={{
              position: 'absolute',
              inset: 0,
              borderRadius: rR,
              background: 'linear-gradient(135deg, #2b3038, #14171c)',
              transform: `translateZ(${backZ}px) rotateY(180deg)`,
              backfaceVisibility: 'hidden',
            }}
          />
        </div>
        {/* Left half: folds over the right half; the cover screen is on its back. */}
        <div
          style={{
            position: 'absolute',
            left: 0,
            top: 0,
            width: bodyW,
            height: bodyH,
            transformStyle: 'preserve-3d',
            transformOrigin: '100% 50%',
            transform: `rotateY(${fold}deg)`,
          }}
        >
          <Extrusion depth={depth} radius={rL} />
          <div style={{position: 'absolute', inset: 0, borderRadius: rL, background: METAL, backfaceVisibility: 'hidden'}} />
          <div
            style={{
              position: 'absolute',
              top: band,
              bottom: band,
              left: band,
              right: 0,
              borderRadius: `${r - band}px 0 0 ${r - band}px`,
              background: '#000',
              backfaceVisibility: 'hidden',
            }}
          />
          {innerLayer('left')}
          {/* Cover */}
          <div
            style={{
              position: 'absolute',
              inset: 0,
              transform: `translateZ(${backZ}px) rotateY(180deg)`,
              backfaceVisibility: 'hidden',
              borderRadius: rR,
              background: METAL,
            }}
          >
            <div style={{position: 'absolute', inset: band, borderRadius: `0 ${r - band}px ${r - band}px 0`, background: '#000'}} />
            <div
              style={{
                position: 'absolute',
                top: band + bezel,
                left: (bodyW - coverW) / 2,
                width: coverW,
                height: coverH,
                borderRadius: rs,
                overflow: 'hidden',
                background: '#000',
              }}
            >
              {outer}
              <Glare radius={rs} />
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
