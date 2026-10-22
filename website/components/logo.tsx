// The pictorial mark (Pascal's triangle: three edges, three vertex
// nodes, and the fainter first node of the next row), inline so it
// inherits currentColor in the navbar and hero.
export function LogoMark({ size = 24 }: { size?: number }) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 32 32"
      fill="none"
      width={size}
      height={size}
      aria-hidden
    >
      <g stroke="currentColor" strokeWidth="2" strokeLinecap="round">
        <path d="M16 7.5 L9.5 18.5" />
        <path d="M16 7.5 L22.5 18.5" />
        <path d="M9.5 18.5 L22.5 18.5" />
      </g>
      <g fill="currentColor">
        <circle cx="16" cy="6" r="3.4" />
        <circle cx="8.5" cy="20" r="3.4" />
        <circle cx="23.5" cy="20" r="3.4" />
      </g>
      <circle cx="16" cy="26" r="2.4" fill="currentColor" opacity="0.45" />
    </svg>
  );
}
