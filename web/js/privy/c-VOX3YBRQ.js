import{d as m,n as u}from"./c-N5TZKW5N.js";import{b as i}from"./c-BWLHDX22.js";import{a as C,b as x}from"./c-Y4USFN7N.js";import{f as p}from"./c-K7HT7LU7.js";var e=p(x(),1);var d=p(C(),1);var a=i.button`
  display: flex;
  align-items: center;
  justify-content: end;
  gap: 0.5rem;

  && {
    color: var(--privy-color-foreground);
    font-weight: 500;
  }

  svg {
    width: 0.875rem;
    height: 0.875rem;
  }
`,f=i.span`
  display: flex;
  align-items: center;
  gap: 0.25rem;
  font-size: 0.875rem;
  color: var(--privy-color-foreground-2);
`,g=i(m)`
  color: var(--privy-color-icon-success);
  flex-shrink: 0;
`,v=i(u)`
  color: var(--privy-color-icon-muted);
  flex-shrink: 0;
`;function z({children:r,iconOnly:l,value:n,hideCopyIcon:t,onCopy:s,iconSize:o=14,...c}){let[y,h]=(0,d.useState)(!1);return(0,e.jsxs)(a,{...c,onClick:()=>{navigator.clipboard.writeText(n||(typeof r=="string"?r:"")).then(()=>s?.()).catch(console.error),h(!0),setTimeout(()=>h(!1),1500)},children:[r," ",y?(0,e.jsxs)(f,{children:[(0,e.jsx)(g,{size:o})," ",!l&&"Copied"]}):!t&&(0,e.jsx)(v,{size:o})]})}var T=({value:r,includeChildren:l,children:n,...t})=>{let[s,o]=(0,d.useState)(!1),c=()=>{navigator.clipboard.writeText(r).catch(console.error),o(!0),setTimeout(()=>o(!1),1500)};return(0,e.jsxs)(e.Fragment,{children:[l?(0,e.jsx)(a,{...t,onClick:c,children:n}):(0,e.jsx)(e.Fragment,{children:n}),(0,e.jsx)(a,{...t,onClick:c,children:s?(0,e.jsx)(f,{children:(0,e.jsx)(g,{})}):(0,e.jsx)(v,{})})]})};export{z as a,T as b};
