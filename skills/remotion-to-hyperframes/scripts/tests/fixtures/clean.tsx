import React from "react";
import {
  useCurrentFrame,
  useVideoConfig,
  AbsoluteFill,
  interpolate,
  spring,
  Sequence,
  staticFile,
  Audio,
  Img,
} from "remotion";

const TitleCard: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const opacity = interpolate(frame, [0, 15], [0, 1], { extrapolateRight: "clamp" });
  const scale = spring({ frame, fps, config: { damping: 12 } });
  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center" }}>
      <div style={{ fontSize: 72, opacity, transform: `scale(${scale})` }}>Hello</div>
      <Img src={staticFile("logo.png")} />
    </AbsoluteFill>
  );
};

export const MyComposition: React.FC = () => (
  <AbsoluteFill>
    <Sequence from={0} durationInFrames={90}>
      <TitleCard />
    </Sequence>
    <Audio src={staticFile("music.mp3")} volume={0.5} />
  </AbsoluteFill>
);
