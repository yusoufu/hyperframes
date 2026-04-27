import React, { useState, useEffect } from "react";
import { useCurrentFrame, AbsoluteFill, delayRender, continueRender } from "remotion";
import { Button } from "@mui/material";

export const BadComposition: React.FC = () => {
  const frame = useCurrentFrame();
  const [data, setData] = useState<string | null>(null);
  const [handle] = useState(() => delayRender());

  // Multi-line useEffect body with commas inside (fillRect args) — regression
  // coverage for r2hf/use-effect-deps. An earlier regex `[^,]+` would stop at
  // the first comma inside the body and miss the deps array entirely.
  useEffect(() => {
    fetch("/api/data")
      .then((r) => r.json())
      .then((d) => {
        const ctx = document.createElement("canvas").getContext("2d");
        ctx?.fillRect(0, 0, 100, 100);
        setData(d.text);
        continueRender(handle);
      });
  }, [handle]);

  return (
    <AbsoluteFill>
      <Button>{data ?? "loading"}</Button>
      <span>{frame}</span>
    </AbsoluteFill>
  );
};

export const calculateMetadata = async () => {
  const res = await fetch("/api/duration");
  const { duration } = await res.json();
  return { durationInFrames: duration };
};
