'use client';

// Self-hosted asciinema player (Apache-2.0; no CDN — the bundle ships
// with the site, the .cast files are committed real recordings under
// docs/casts/, synced into public/docs-casts/). Client-only: the
// player touches window/DOM, so it mounts in useEffect — which never
// runs during the static export — and disposes on unmount (required
// for React StrictMode double-mounting).
import { useEffect, useRef } from 'react';
import 'asciinema-player/dist/bundle/asciinema-player.css';

export function TerminalCast({ src, label }: { src: string; label?: string }) {
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    let player: { dispose(): void } | undefined;
    let cancelled = false;
    void import('asciinema-player').then((AsciinemaPlayer) => {
      if (cancelled || !container) return;
      player = AsciinemaPlayer.create(src, container, {
        theme: 'pascal-mcp-sdk',
        terminalFontFamily:
          "ui-monospace, SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace",
        fit: 'width',
        idleTimeLimit: 2,
        poster: 'npt:0:2',
      }) as { dispose(): void };
    });
    return () => {
      cancelled = true;
      player?.dispose();
    };
  }, [src]);

  return (
    <figure className="terminal-cast" aria-label={label ?? 'Terminal session'}>
      <div ref={containerRef} />
      {label ? (
        <figcaption className="text-center text-xs text-fd-muted-foreground mt-1">
          {label} —{' '}
          <a href={src} className="underline">
            .cast file
          </a>
        </figcaption>
      ) : null}
    </figure>
  );
}
