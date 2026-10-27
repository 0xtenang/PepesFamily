import{a,b as n,c as s}from"./c-EO5666TK.js";import{c as i,d as t}from"./c-6SGKDJ7B.js";import{a as o,b as r}from"./c-BWLHDX22.js";var d=o`
  font-size: 14px;
  font-style: normal;
  font-weight: 400;
  line-height: 20px;
  letter-spacing: -0.008px;
  text-align: left;
  transition: color 0.1s ease-in;
`,m=r.span`
  ${d}
  transition: color 0.1s ease-in;
  color: ${({error:e})=>e?"var(--privy-color-error)":"var(--privy-color-foreground-3)"};
  text-transform: ${({error:e})=>e?"":"capitalize"};

  &[aria-hidden='true'] {
    visibility: hidden;
  }
`,u=r.div`
  display: flex;
  flex-direction: column;
  justify-content: center;
  flex-grow: 1;
`,y=r(t)`
  ${({$hideAnimations:e})=>e&&o`
      && {
        transition: none;
      }
    `}
`,c=o`
  && {
    width: 100%;
    border-width: 1px;
    border-radius: var(--privy-border-radius-md);
    border-color: var(--privy-color-foreground-3);
    background: var(--privy-color-background);
    color: var(--privy-color-foreground);

    padding: 12px;
    font-size: 16px;
    font-style: normal;
    font-weight: 300;
    line-height: 22px; /* 137.5% */
  }
`,b=r.input`
  ${c}

  &::placeholder {
    color: var(--privy-color-foreground-3);
    font-style: italic;
    font-size: 14px;
  }

  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
`,w=r.div`
  ${c}
`,k=r.div`
  position: relative;
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: ${({centered:e})=>e?"center":"space-between"};
`,$=r.div`
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  margin: 32px 0;
  gap: 4px;

  & h3 {
    font-size: 18px;
    font-style: normal;
    font-weight: 600;
    line-height: 24px;
  }

  & p {
    max-width: 300px;
    font-size: 14px;
    font-style: normal;
    font-weight: 400;
    line-height: 20px;
  }
`,z=r.div`
  display: flex;
  flex-direction: column;
  gap: 10px;
  padding-bottom: 1rem;
`,j=r.div`
  display: flex;
  text-align: left;
  align-items: center;

  gap: 8px;
  max-width: 300px;

  font-size: 14px;
  font-style: normal;
  font-weight: 400;
  line-height: 20px;
  letter-spacing: -0.008px;

  margin: 0 8px;
  color: var(--privy-color-foreground-2);

  > :first-child {
    min-width: 24px;
  }
`;r.div`
  height: var(--privy-height-modal-full);

  @media (max-width: 440px) {
    height: var(--privy-height-modal-compact);
  }
`;var N=r(i)`
  display: flex;
  flex: 1;
  gap: 4px;
  justify-content: center;

  && {
    background: var(--privy-color-background);
    border-radius: var(--privy-border-radius-md);
    border-color: var(--privy-color-foreground-3);
    border-width: 1px;
  }
`,P=r.div`
  position: absolute;
  right: 0.5rem;

  display: flex;
  flex-direction: row;
  justify-content: space-around;
  align-items: center;
`,S=r(a)`
  height: 1.25rem;
  width: 1.25rem;
  stroke: var(--privy-color-accent);
  cursor: pointer;

  :active {
    stroke: var(--privy-color-accent-light);
  }
`,A=r(n)`
  height: 1.25rem;
  width: 1.25rem;
  stroke: var(--privy-color-accent);
  cursor: pointer;

  :active {
    stroke: var(--privy-color-accent-light);
  }
`,B=r(s)`
  height: 1.25rem;
  width: 1.25rem;
  stroke: var(--privy-color-accent);
  cursor: pointer;

  :active {
    stroke: var(--privy-color-accent-light);
  }
`,l=o`
  border-radius: 8px;
  background: var(--privy-color-foreground-4);
`,p=o`
  border-radius: 8px;
  transition: all 0.1s ease-out;
  background: ${({$label:e})=>(e==="Strong"?"var(--privy-color-icon-success)":e==="Medium"&&"var(--privy-color-icon-warning)")||"var(--privy-color-icon-error)"};
`,D=r.progress`
  height: 4px;
  width: 100%;
  margin: 8px 0;

  /* Neither engine exposes its pseudo-elements until the native widget is opted out of. */
  appearance: none;

  /* Firefox's track, and a fallback under the WebKit bar. */
  ${l}

  &::-webkit-progress-bar {
    ${l}
  }

  &::-webkit-progress-value {
    ${p}
  }

  &::-moz-progress-bar {
    ${p}
  }
`;export{m as a,u as b,y as c,b as d,w as e,k as f,$ as g,z as h,j as i,N as j,P as k,S as l,A as m,B as n,D as o};
