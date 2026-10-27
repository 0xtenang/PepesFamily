import{d as r}from"./c-X53Y5QLE.js";import{h as i}from"./c-6SGKDJ7B.js";import{b as t,d as o}from"./c-BWLHDX22.js";var d=t.div`
  display: flex;
  flex-direction: column;
  gap: 12px;
  padding-top: 24px;
  padding-bottom: 24px;
`,c=t.div`
  width: 24px;
  height: 24px;
  display: flex;
  justify-content: center;
  align-items: center;

  svg {
    border-radius: var(--privy-border-radius-sm);
  }
`,l=t.div`
  display: flex;
  flex-direction: column;
  justify-content: center;
  align-items: flex-start;
  gap: 8px;
`,x=t.div`
  display: flex;
  align-items: center;
  gap: 4px;
  width: 100%;
  padding: 0 16px;
  border-width: 1px !important;
  border-radius: 12px;
  cursor: text;

  &:focus-within {
    border-color: var(--privy-color-accent);
  }
`;t.div`
  font-size: 42px !important;
`;var e=t.input`
  background-color: var(--privy-color-background);
  width: 100%;

  &:focus {
    outline: none !important;
    border: none !important;
    box-shadow: none !important;
  }

  && {
    font-size: 26px;
  }
`,f=t(e)`
  && {
    font-size: 42px;
  }
`;t.button`
  cursor: pointer;
  padding-left: 4px;
`;var m=t.div`
  font-size: 18px;
`,g=t.div`
  font-size: 12px;
  color: var(--privy-color-foreground-3);
  /* we need this container to maintain a static height if there's no content */
  height: 20px;
`;t.div`
  display: flex;
  flex-direction: row;
  line-height: 22px;
  font-size: 16px;
  text-align: center;
  svg {
    margin: auto;
  }
`,t(r)`
  margin-top: 16px;
`;var n=o`
  from {
    opacity: 0;
  }
  to {
    opacity: 1;
  }
`;t(i)`
  border-radius: var(--privy-border-radius-md) !important;
  animation: ${n} 0.3s ease-in-out;
`;var u=t.a`
  && {
    color: var(--privy-color-accent);
  }

  cursor: pointer;
`;export{d as a,c as b,l as c,x as d,e,f,m as g,g as h,u as i};
