// T4 case 05 — Imports @remotion/lambda for distributed rendering config.
//
// Should be detected by lint_source.py as blocker r2hf/lambda-import.
// The skill should drop the Lambda code with a note (HF runs single-machine
// today) and translate the rest of the composition only if no other blockers
// are present.
//
// Why this is a blocker: @remotion/lambda is Remotion's AWS-Lambda-based
// distributed renderer. HF doesn't have an equivalent — render is
// single-machine. The skill cannot translate this configuration.

import React from "react";
import { renderMediaOnLambda } from "@remotion/lambda";
import { AbsoluteFill, useCurrentFrame, interpolate } from "remotion";

export const LambdaConfigured: React.FC = () => {
  const frame = useCurrentFrame();
  const opacity = interpolate(frame, [0, 30], [0, 1]);
  return (
    <AbsoluteFill style={{ opacity }}>
      <div>frame {frame}</div>
    </AbsoluteFill>
  );
};

// Rendered at scale via Lambda — no HF equivalent.
export async function renderViaLambda() {
  return renderMediaOnLambda({
    region: "us-east-1",
    functionName: "remotion-render",
    composition: "LambdaConfigured",
    serveUrl: "https://example.com/bundle",
    inputProps: {},
    codec: "h264",
  });
}
